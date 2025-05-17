import json
import black
import re
from pathlib import Path
from tqdm import tqdm
import logging
import ast
import os

# Create log directory first
os.makedirs("../logs", exist_ok=True)

# Set up logging only after directory exists
logging.basicConfig(
    level=logging.INFO, 
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler("../logs/normalize.log"),
        logging.StreamHandler()
    ]
)

def normalize_code(code_str):
    """Apply multiple normalization steps to clean up code"""
    try:
        # Step 1: Format with Black
        formatted = black.format_str(code_str, mode=black.FileMode())
        
        # Step 2: Remove common import variations
        # (keeps the imports but standardizes formatting)
        formatted = re.sub(r'import\s+([a-zA-Z0-9_]+)\s+as\s+([a-zA-Z0-9_]+)', r'import \1 as \2', formatted)
        
        # Step 3: Standardize docstrings (convert all to triple double quotes)
        formatted = re.sub(r"'''(.+?)'''", r'"""\1"""', formatted, flags=re.DOTALL)
        
        return formatted
    except Exception as e:
        logging.warning(f"Normalization failed: {str(e)}")
        return code_str  # Return original if formatting fails

def normalize_dataset(input_path, output_path):
    logging.info(f"Loading dataset from {input_path}")
    try:
        data = json.loads(Path(input_path).read_text())
    except Exception as e:
        logging.error(f"Failed to load dataset: {str(e)}")
        return
    
    logging.info(f"Processing {len(data)} entries")
    normalized_count = 0
    skipped_count = 0
    
    # Process entries with progress bar
    for entry in tqdm(data, desc="Normalizing test code"):
        for test in entry['tests']:
            original = test['body']
            try:
                normalized = normalize_code(original)
                test['body'] = normalized
                
                if original != normalized:
                    normalized_count += 1
            except Exception as e:
                logging.warning(f"Failed to normalize test {test.get('name', 'unknown')}: {str(e)}")
                skipped_count += 1
    
    # Save normalized dataset
    logging.info(f"Saving normalized dataset to {output_path}")
    Path(output_path).write_text(json.dumps(data, indent=2))
    
    logging.info(f"Normalization complete: {normalized_count} tests normalized, {skipped_count} tests skipped")
    return data

if __name__ == "__main__":
    # Define paths
    input_path = "../dataset/python_tests_deduped.json"
    output_path = "../dataset/python_tests_normalized.json"
    
    # Run normalization
    normalize_dataset(input_path, output_path)
    
    logging.info("Done!")