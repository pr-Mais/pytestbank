import json
from collections import defaultdict, Counter
from pathlib import Path

print("Loading dataset...")
data = json.loads(Path("../dataset/python_tests.json").read_text())
print(f"Loaded {len(data)} test entries from {len(set(entry['repo'] for entry in data))} repositories")

# Initialize tracking
total_tests = 0
unique_tests = {}
duplicate_counts = defaultdict(int)
repo_duplicate_counts = Counter()
dedup_stats = {
    "original_entries": len(data),
    "original_tests": sum(len(entry['tests']) for entry in data),
    "unique_entries": 0,
    "unique_tests": 0,
    "duplicate_entries": 0,
    "duplicate_tests": 0,
    "repositories_with_duplicates": 0,
    "top_duplicate_repos": []
}

print("Deduplicating tests...")
for entry in data:
    repo = entry['repo']
    file_path = entry['file']
    
    # Track test counts
    test_count = len(entry['tests'])
    total_tests += test_count
    
    # Create a unique key using file path and test content
    for test in entry['tests']:
        # Use test body as the key for deduplication
        key = test['body']
        
        if key not in unique_tests:
            unique_tests[key] = test
        else:
            # Count this duplicate
            duplicate_counts[key] += 1
            repo_duplicate_counts[repo] += 1

# Create deduplicated dataset
deduplicated_data = []
seen_files = set()

for entry in data:
    # Only keep tests that are in our unique set
    unique_entry_tests = [test for test in entry['tests'] 
                         if test['body'] in unique_tests and unique_tests[test['body']] == test]
    
    if unique_entry_tests:
        # Create a new entry with only unique tests
        new_entry = entry.copy()
        new_entry['tests'] = unique_entry_tests
        
        # Track unique file+repo combinations
        file_repo_key = f"{entry['repo']}:{entry['file']}"
        if file_repo_key not in seen_files:
            seen_files.add(file_repo_key)
            deduplicated_data.append(new_entry)

# Calculate stats
dedup_stats["unique_entries"] = len(deduplicated_data)
dedup_stats["unique_tests"] = len(unique_tests)
dedup_stats["duplicate_entries"] = dedup_stats["original_entries"] - dedup_stats["unique_entries"]
dedup_stats["duplicate_tests"] = dedup_stats["original_tests"] - dedup_stats["unique_tests"]
dedup_stats["repositories_with_duplicates"] = len(repo_duplicate_counts)

# Get top 10 repositories with most duplicates
top_repos = repo_duplicate_counts.most_common(10)
dedup_stats["top_duplicate_repos"] = [{"repo": repo, "duplicates": count} for repo, count in top_repos]

# Save deduplicated dataset
Path("../dataset/python_tests_deduped.json").write_text(
    json.dumps(deduplicated_data, indent=2)
)

# Save deduplication statistics
Path("../dataset/deduplication_stats.json").write_text(
    json.dumps(dedup_stats, indent=2)
)

# Print summary
print("\nDEDUPLICATION SUMMARY:")
print(f"Original dataset: {dedup_stats['original_entries']} entries with {dedup_stats['original_tests']} tests")
print(f"Deduplicated dataset: {dedup_stats['unique_entries']} entries with {dedup_stats['unique_tests']} tests")
print(f"Removed {dedup_stats['duplicate_tests']} duplicate tests ({(dedup_stats['duplicate_tests']/dedup_stats['original_tests']*100):.1f}%)")
print(f"Found duplicates in {dedup_stats['repositories_with_duplicates']} repositories")

if top_repos:
    print("\nTop repositories with duplicates:")
    for repo, count in top_repos[:5]:
        print(f"  {repo}: {count} duplicates")

print(f"\nDetailed statistics saved to ../dataset/deduplication_stats.json")