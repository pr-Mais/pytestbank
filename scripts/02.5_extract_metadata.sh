#!/bin/bash
# scripts/04_gh_metadata.sh - Clean output version

# Configuration
INPUT_FILE="../repos_with_tests.txt"
OUTPUT_FILE="../repos_metadata.json"
FAILED_FILE="../failed_metadata_repos.txt"
RETRY_FILE="../retry_metadata_repos.txt"
LOG_FILE="../metadata_extraction.log"
CONCURRENT_JOBS=4
MAX_RETRIES=3
RETRY_DELAY=5

# Initialize files
mkdir -p "$(dirname "$OUTPUT_FILE")"
echo '[]' > "$OUTPUT_FILE"
> "$FAILED_FILE"
> "$RETRY_FILE"
> "$LOG_FILE"

# Verify input file exists
if [ ! -f "$INPUT_FILE" ]; then
    echo "❌ Error: Input file $INPUT_FILE not found!" | tee -a "$LOG_FILE"
    exit 1
fi

# Function to process a single repo with retries
process_repo() {
    local owner_repo="$1"
    local current="$2"
    local total="$3"
    local attempt=1
    local success=false
    
    while [ $attempt -le $MAX_RETRIES ] && [ "$success" = false ]; do
        # Get repo metadata
        if repo_data=$(gh api "repos/$owner_repo" --jq '{
            name,
            owner: .owner.login,
            url: .html_url,
            description,
            stars: .stargazers_count,
            forks: .forks_count,
            watchers: .subscribers_count,
            issues: .open_issues_count,
            created_at,
            updated_at,
            pushed_at,
            license: (.license.spdx_id // "none"),
            archived,
            disabled,
            is_fork: .fork,
            fork_parent: (.parent.full_name // null),
            fork_source: (.source.full_name // null),
            size_kb: .size,
            default_branch
        }' 2>> "$LOG_FILE"); then
            
            # Create metadata with owner_repo
            metadata=$(jq -c --arg owner_repo "$owner_repo" \
                '. + {owner_repo: $owner_repo}' <<< "$repo_data")

            # Atomic update with temp file
            temp_file=$(mktemp)
            if jq --argjson meta "$metadata" '. += [$meta]' "$OUTPUT_FILE" > "$temp_file" 2>> "$LOG_FILE"; then
                mv "$temp_file" "$OUTPUT_FILE"
                echo "✅ [$current/$total] Processed: $owner_repo" | tee -a "$LOG_FILE"
                success=true
            else
                echo "⚠️ [$current/$total] Update failed for $owner_repo" | tee -a "$LOG_FILE"
            fi
            rm -f "$temp_file"
        else
            echo "⚠️ [$current/$total] API failed for $owner_repo" | tee -a "$LOG_FILE"
        fi

        if [ "$success" = false ]; then
            ((attempt++))
            if [ $attempt -le $MAX_RETRIES ]; then
                sleep $RETRY_DELAY
            fi
        fi
    done

    if [ "$success" = false ]; then
        echo "❌ [$current/$total] Failed: $owner_repo" | tee -a "$LOG_FILE"
        echo "$owner_repo" >> "$FAILED_FILE"
    fi
}

# Main execution
echo "Starting metadata extraction at $(date)" | tee -a "$LOG_FILE"

# Verify and clean input file
CLEAN_INPUT=$(mktemp)
grep -v '^[[:space:]]*$' "$INPUT_FILE" | sort -u > "$CLEAN_INPUT"
ACTUAL_TOTAL=$(wc -l < "$CLEAN_INPUT")
echo "=== Processing $ACTUAL_TOTAL unique repositories ===" | tee -a "$LOG_FILE"

# Process with limited concurrency
current=0
while IFS= read -r owner_repo; do
    ((current++))
    process_repo "$owner_repo" "$current" "$ACTUAL_TOTAL" &
    
    # Limit concurrent jobs
    if (( current % CONCURRENT_JOBS == 0 )); then
        wait
    fi
done < "$CLEAN_INPUT"
wait


# Retry failed repos
retry_count=1
while [ $retry_count -le $MAX_RETRIES ] && [ -f "$FAILED_FILE" ] && [ -s "$FAILED_FILE" ]; do
    RETRY_TOTAL=$(wc -l < "$FAILED_FILE")
    echo -e "\n=== Retry $retry_count/$MAX_RETRIES ($RETRY_TOTAL repos) ===" | tee -a "$LOG_FILE"
    
    mv "$FAILED_FILE" "$RETRY_FILE"
    > "$FAILED_FILE"
    
    current=0
    while IFS= read -r owner_repo; do
        if [ -z "$owner_repo" ]; then continue; fi
        
        ((current++))
        process_repo "$owner_repo" "$current" "$RETRY_TOTAL" &
        
        if (( current % CONCURRENT_JOBS == 0 )); then
            wait
        fi
    done < "$RETRY_FILE"
    wait
    
    ((retry_count++))
done

# Final report - use ACTUAL_TOTAL instead of TOTAL_REPOS
SUCCESS_COUNT=$(jq length "$OUTPUT_FILE")
FINAL_FAILED=$([ -f "$FAILED_FILE" ] && wc -l < "$FAILED_FILE" | tr -d ' ' || echo 0)
echo -e "\n=== Results ===" | tee -a "$LOG_FILE"
echo "Total unique repositories: $ACTUAL_TOTAL" | tee -a "$LOG_FILE" 
echo "Successfully processed: $SUCCESS_COUNT" | tee -a "$LOG_FILE"
echo "Failed after retries: $FINAL_FAILED" | tee -a "$LOG_FILE"
echo "Output file: $OUTPUT_FILE" | tee -a "$LOG_FILE"
[ "$FINAL_FAILED" -gt 0 ] && echo "Failed repos: $FAILED_FILE" | tee -a "$LOG_FILE"
echo "Completed at $(date)" | tee -a "$LOG_FILE"

# Cleanup
rm -f "$CLEAN_INPUT"