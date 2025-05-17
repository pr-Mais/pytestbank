#!/bin/bash
mkdir -p ../clones
rm -f ../clones/repo_urls.txt

# Split by stars ranges to work around the 1000 results limit
declare -a ranges=(
  "stars:40..100"
  "stars:100..500"
  "stars:500..1000" 
  "stars:1000..5000"
  "stars:>5000"
)

for range in "${ranges[@]}"; do
  echo "Fetching repositories with $range"
  gh api -X GET search/repositories \
    -f q="language:python $range pushed:>2024-01-01" \
    --paginate | jq -r '.items[].clone_url' >> ../clones/repo_urls.txt
  
  # Respect rate limits
  sleep 2
done

# Remove any duplicates
sort -u ../clones/repo_urls.txt -o ../clones/repo_urls.txt

echo "Total repositories found: $(wc -l < ../clones/repo_urls.txt)"
echo "Saved repo URLs to ../clones/repo_urls.txt"