import json
import ast
from pathlib import Path
import datetime
import multiprocessing
from functools import partial
import os

def extract_test_functions(file_path):
    """Parse Python file and extract test function names and bodies"""
    try:
        with open(file_path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()

        # Quick check - if no test-related terms, skip parsing
        if not ("test" in content.lower() or "unittest" in content.lower() or "pytest" in content.lower()):
            return [], None

        # Try to parse the file
        try:
            tree = ast.parse(content)
        except SyntaxError:
            # If parsing fails, try to fix common f-string issues
            content_fixed = content.replace("f'{", "f'{").replace("}'", "}'")
            try:
                tree = ast.parse(content_fixed)
            except SyntaxError as e:
                return [], f"SyntaxError: {str(e)}"

        tests = []

        # Find test classes and functions
        for node in ast.walk(tree):
            # Test functions (either named test_* or with pytest decorator)
            if isinstance(node, ast.FunctionDef) and (
                node.name.startswith("test_")
                or node.name.endswith("_test")
                or any(
                    isinstance(decorator, ast.Call)
                    and hasattr(decorator.func, "attr")
                    and decorator.func.attr == "mark"
                    for decorator in node.decorator_list
                )
                or any(
                    isinstance(decorator, ast.Name)
                    and hasattr(decorator, "id")
                    and "test" in decorator.id.lower()
                    for decorator in node.decorator_list
                )
            ):
                try:
                    func_source = ast.get_source_segment(content, node)
                    if func_source:
                        tests.append(
                            {
                                "name": node.name,
                                "body": func_source,
                                "file": str(file_path),
                            }
                        )
                except Exception:
                    continue

            # TestCase classes (unittest)
            if isinstance(node, ast.ClassDef) and any(
                "TestCase" in base.id for base in node.bases if hasattr(base, "id")
            ):
                for item in node.body:
                    if isinstance(item, ast.FunctionDef) and item.name.startswith(
                        ("test_", "test")
                    ):
                        try:
                            method_source = ast.get_source_segment(content, item)
                            if method_source:
                                tests.append(
                                    {
                                        "name": f"{node.name}.{item.name}",
                                        "body": method_source,
                                        "file": str(file_path),
                                        "class": node.name,
                                    }
                                )
                        except Exception:
                            continue

        return tests, None
    except Exception as e:
        return [], f"Error processing file: {str(e)}"

def process_repo(repo, clones_dir):
    """Process a single repository and return its data and metadata"""
    repo_path = clones_dir / repo.split("/")[-1]
    if not repo_path.exists():
        return repo, {
            "status": "skipped",
            "error": "Directory not found",
        }, []

    test_files_count = 0
    test_functions_count = 0
    failed_files = []
    processed_files = 0
    dataset_entries = []

    repo_metadata = {
        "status": "processed",
        "test_files_count": 0,
        "test_functions_count": 0,
        "processed_files": 0,
        "failed_files": [],
    }

    # More efficient file finding - directly target test files
    test_files = []
    for root, _, files in os.walk(repo_path):
        for file in files:
            if file.endswith(".py") and ("test" in file.lower() or "test" in root.lower()):
                test_files.append(Path(os.path.join(root, file)))

    for test_file in test_files:
        processed_files += 1
        tests, error = extract_test_functions(test_file)
        
        if error:
            relative_path = str(test_file.relative_to(repo_path))
            failed_files.append({"file": relative_path, "error": error})
            repo_metadata["failed_files"].append(
                {"file": relative_path, "error": error}
            )

        if tests:
            test_files_count += 1
            test_functions_count += len(tests)
            dataset_entries.append(
                {
                    "repo": repo,
                    "file": str(test_file.relative_to(repo_path)),
                    "tests": tests,
                }
            )

    repo_metadata["test_files_count"] = test_files_count
    repo_metadata["test_functions_count"] = test_functions_count
    repo_metadata["processed_files"] = processed_files
    repo_metadata["failed_files_count"] = len(failed_files)
    
    return repo, repo_metadata, dataset_entries

def main():
    clones_dir = Path("../clones")
    output_dir = Path("../dataset")
    output_dir.mkdir(exist_ok=True)

    # Check if repos directory exists
    if not clones_dir.exists():
        print(f"ERROR: Clones directory not found at {clones_dir}")
        exit(1)

    repos_file = Path("../repos_with_tests.txt")
    if not repos_file.exists():
        print(f"ERROR: repos_with_tests.txt not found at {repos_file}")
        exit(1)

    # Initialize metadata tracking
    extraction_metadata = {
        "timestamp": datetime.datetime.now().isoformat(),
        "total_repositories": 0,
        "successful_repositories": 0,
        "total_test_files_found": 0,
        "total_test_functions_found": 0,
        "repositories": {},
    }

    repos = [line.strip() for line in repos_file.read_text().splitlines() if line.strip()]
    print(f"Found {len(repos)} repositories to process")
    extraction_metadata["total_repositories"] = len(repos)

    # Process repositories in parallel
    num_processes = max(1, multiprocessing.cpu_count() - 1)  # Leave one CPU free
    print(f"Using {num_processes} processes for parallel processing")
    
    dataset = []
    
    with multiprocessing.Pool(processes=num_processes) as pool:
        results = []
        for i, result in enumerate(pool.imap_unordered(partial(process_repo, clones_dir=clones_dir), repos)):
            repo, repo_metadata, repo_dataset = result
            
            # Print progress
            print(f"[{i+1}/{len(repos)}] Processed {repo}: {repo_metadata['test_files_count']} test files, {repo_metadata['test_functions_count']} test functions")
            
            # Update metadata
            extraction_metadata["repositories"][repo] = repo_metadata
            
            if repo_metadata["test_files_count"] > 0:
                extraction_metadata["successful_repositories"] += 1
                extraction_metadata["total_test_files_found"] += repo_metadata["test_files_count"]
                extraction_metadata["total_test_functions_found"] += repo_metadata["test_functions_count"]
                
            # Add to dataset
            dataset.extend(repo_dataset)

    # Write dataset to file
    if dataset:
        (output_dir / "python_tests.json").write_text(json.dumps(dataset, indent=2))
        print(f"Extracted {len(dataset)} test files to ../dataset/python_tests.json")
    else:
        print("No test files were found!")

    # Write metadata report
    (output_dir / "extraction_metadata.json").write_text(
        json.dumps(extraction_metadata, indent=2)
    )
    print(f"Extraction report saved to ../dataset/extraction_metadata.json")

    # Print summary
    success_rate = (
        (
            extraction_metadata["successful_repositories"]
            / extraction_metadata["total_repositories"]
        )
        * 100
        if extraction_metadata["total_repositories"] > 0
        else 0
    )
    print("\nEXTRACTION SUMMARY:")
    print(f"Repositories processed: {extraction_metadata['total_repositories']}")
    print(
        f"Repositories with tests: {extraction_metadata['successful_repositories']} ({success_rate:.1f}%)"
    )
    print(f"Total test files found: {extraction_metadata['total_test_files_found']}")
    print(
        f"Total test functions found: {extraction_metadata['total_test_functions_found']}"
    )

if __name__ == "__main__":
    main()