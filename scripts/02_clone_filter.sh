#!/bin/bash
cd ../clones || exit

# Initialize files with proper locking
> ../repos_with_tests.txt
> ../excluded_tutorial_repos.txt
> ../excluded_no_tests_repos.txt
> ../failed_clone_repos.txt
if [ ! -f ../repos_metadata.json ]; then
  echo '{}' > ../repos_metadata.json
fi

# Function to safely update JSON
update_metadata() {
  local owner_repo="$1"
  local metadata="$2"
  
  # Create temp file
  local temp_file
  temp_file=$(mktemp)
  
  # Read current metadata
  current_metadata=$(cat ../repos_metadata.json)
  
  # Update and write to temp file
  jq --argjson meta "$metadata" \
     ".[\"$owner_repo\"] = \$meta" <<< "$current_metadata" > "$temp_file"
  
  # Atomic move
  mv "$temp_file" ../repos_metadata.json
}

# Enhanced test detection function
detect_tests() {
  repo_dir="$1"
  
  # Find test files by pattern
  test_pattern_files=$(find "$repo_dir" -type f \( \
    -name "test_*.py" -o \
    -name "*_test.py" -o \
    -name "*_spec.py" -o \
    -name "tests.py" -o \
    -path "*/tests/*.py" -o \
    -path "*/test/*.py" \) | wc -l | xargs)

  # Detect test frameworks
  pytest_files=$(find "$repo_dir" -type f -name "*.py" -exec \
    grep -l -E "import pytest|@pytest|pytest\.mark" {} + | wc -l | xargs)
  
  unittest_files=$(find "$repo_dir" -type f -name "*.py" -exec \
    grep -l -E "import unittest|from unittest import|unittest\.TestCase|TestCase\(" {} + | wc -l | xargs)

  # Additional metrics
  total_files=$(find "$repo_dir" -type f | wc -l | xargs)
  python_files=$(find "$repo_dir" -type f -name "*.py" | wc -l | xargs)
  last_updated=$(cd "$repo_dir" && git log -1 --format=%cd --date=short 2>/dev/null || echo "unknown")

  echo "$test_pattern_files $pytest_files $unittest_files $total_files $python_files $last_updated"
}

# Main processing function
process_repo() {
  repo_url="$1"
  current="$2"
  total="$3"
  repo_name=$(basename "$repo_url" .git)
  owner_repo=$(echo "$repo_url" | sed -E 's|.*github\.com/([^/]+/[^/]+)\.git|\1|')
  
  # Skip if already in metadata
  if jq -e "has(\"$owner_repo\")" ../repos_metadata.json >/dev/null; then
    echo "✓ [$current/$total] $owner_repo already processed - skipping"
    return 0
  fi

  # Check if repo directory exists but wasn't processed yet
  if [ -d "$repo_name" ]; then
    echo "↻ [$current/$total] Found existing clone for $owner_repo - analyzing"
  else
    # Clone with timeout
    if ! timeout 120 git clone --depth 1 "$repo_url" 2>/dev/null; then
      echo "⚠️ [$current/$total] Failed to clone $repo_url"
      echo "$owner_repo" >> ../failed_clone_repos.txt
      return 1
    fi
  fi

  # Check for tutorial repos
  if [ -f "$repo_name/README.md" ] && \
     grep -i -E "(tutorial|course|homework|example|demo|starter).*(code|project)" "$repo_name/README.md" 2>/dev/null | grep -q .; then
    echo "🔍 [$current/$total] $owner_repo excluded (tutorial)"
    echo "$owner_repo" >> ../excluded_tutorial_repos.txt
    rm -rf "$repo_name"
    return 1
  fi

  # Get test metrics
  read test_count pytest_count unittest_count total_files python_files last_updated <<< \
    $(detect_tests "$repo_name")
  
  # Get GitHub metadata
  repo_data=$(gh api "repos/$owner_repo" 2>/dev/null || echo '{}')
  
  stars=$(jq -r '.stargazers_count // 0' <<< "$repo_data")
  forks=$(jq -r '.forks_count // 0' <<< "$repo_data")
  watchers=$(jq -r '.watchers_count // 0' <<< "$repo_data")
  issues=$(jq -r '.open_issues_count // 0' <<< "$repo_data")
  created_at=$(jq -r '.created_at // "unknown"' <<< "$repo_data")
  updated_at=$(jq -r '.updated_at // "unknown"' <<< "$repo_data")
  description=$(jq -r '.description // ""' <<< "$repo_data")
  license=$(jq -r '.license.spdx_id // "none"' <<< "$repo_data")

  # Build metadata
  metadata=$(jq -n \
    --arg name "$repo_name" \
    --arg owner_repo "$owner_repo" \
    --arg url "$repo_url" \
    --arg description "$description" \
    --argjson stars "$stars" \
    --argjson forks "$forks" \
    --argjson watchers "$watchers" \
    --argjson issues "$issues" \
    --arg created_at "$created_at" \
    --arg updated_at "$updated_at" \
    --arg license "$license" \
    --argjson test_count "$test_count" \
    --argjson pytest_count "$pytest_count" \
    --argjson unittest_count "$unittest_count" \
    --argjson total_files "$total_files" \
    --argjson python_files "$python_files" \
    --arg last_updated "$last_updated" \
    '{
      name: $name,
      owner_repo: $owner_repo,
      url: $url,
      description: $description,
      stars: $stars,
      forks: $forks,
      watchers: $watchers,
      issues: $issues,
      created_at: $created_at,
      updated_at: $updated_at,
      license: $license,
      test_files_count: $test_count,
      pytest_files: $pytest_count,
      unittest_files: $unittest_count,
      total_files: $total_files,
      python_files: $python_files,
      last_updated: $last_updated
    }')

  # Update records
  if [ "$test_count" -gt 0 ] || [ "$pytest_count" -gt 0 ] || [ "$unittest_count" -gt 0 ]; then
    echo "$owner_repo" >> ../repos_with_tests.txt
    echo "✅ [$current/$total] $owner_repo: $test_count test files (⭐$stars)"
    
    # Update metadata safely
    update_metadata "$owner_repo" "$metadata"
  else
    echo "❌ [$current/$total] $owner_repo: No tests found"
    echo "$owner_repo" >> ../excluded_no_tests_repos.txt
    rm -rf "$repo_name"
    return 1
  fi
}

# Export functions for parallel
export -f process_repo detect_tests update_metadata

# Check for GNU Parallel (preferred) or fallback to xargs
if command -v parallel >/dev/null; then
  echo "Using GNU Parallel for processing"
  total_repos=$(wc -l < repo_urls.txt)
  cat repo_urls.txt | parallel -j 8 --bar --eta --progress "process_repo {} {#} $total_repos"
else
  echo "Using xargs for processing (install GNU Parallel for better performance)"
  total_repos=$(wc -l < repo_urls.txt)
  current=0
  while read -r url; do
    current=$((current + 1))
    process_repo "$url" "$current" "$total_repos"
    sleep 2  # Rate limiting
  done < repo_urls.txt
fi

# Final report
echo -e "\n=== Processing Complete ==="
echo "Repos with tests:    $(wc -l < ../repos_with_tests.txt)"
echo "Excluded tutorials:  $(wc -l < ../excluded_tutorial_repos.txt)"
echo "Excluded no tests:   $(wc -l < ../excluded_no_tests_repos.txt)"
echo "Failed clones:       $(wc -l < ../failed_clone_repos.txt)"
echo "Metadata saved to:   ../repos_metadata.json"
echo "Metadata entries:    $(jq length ../repos_metadata.json)"