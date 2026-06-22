#!/bin/bash

set -euo pipefail

OPENSEARCH_URL="http://localhost:9200"
OPENSEARCH_VERSION=${1:-"2.19.2"}
TEST_RESULTS_FILE=${TEST_RESULTS_FILE:-"test-results.txt"}
INDEX_NAME=${INDEX_NAME:-"repro_named_queries"}
OPENSEARCH_CONTAINER_ID=""
DUP_RESULT="UNKNOWN"
DISTINCT_RESULT="UNKNOWN"
BUG_STATUS="UNKNOWN"

echo "Testing OpenSearch version: ${OPENSEARCH_VERSION}"

retry_command() {
    local cmd="$1"
    local max_attempts=3
    local attempt=1
    local exit_code=0
    local wait_time=10

    while [[ $attempt -le $max_attempts ]]; do
        echo "Attempt $attempt of $max_attempts: Running command..."
        eval "$cmd"
        exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            return 0
        else
            echo "Attempt $attempt failed with exit code $exit_code."
            if [[ $attempt -lt $max_attempts ]]; then
                echo "Waiting ${wait_time} seconds before retry..."
                sleep $wait_time
                wait_time=$((wait_time * 2))
                ((attempt++))
            else
                echo "All $max_attempts attempts failed!"
                return $exit_code
            fi
        fi
    done
}

pull_docker_image() {
    local image_name="$1"
    echo "Pulling Docker image: $image_name"
    if docker image inspect "$image_name" &>/dev/null; then
        echo "Image already exists locally, skipping pull."
        return 0
    fi
    retry_command "docker pull $image_name"
    return $?
}

check_opensearch() {
    if ! curl -s "${OPENSEARCH_URL}/_cluster/health" > /dev/null 2>&1; then
        echo "Starting OpenSearch ${OPENSEARCH_VERSION}..."
        local image_name="public.ecr.aws/opensearchproject/opensearch:${OPENSEARCH_VERSION}"

        if ! pull_docker_image "$image_name"; then
            echo "Failed to pull Docker image after multiple attempts. Trying to continue with existing image..."
        fi

        local container_id=""
        if [[ "${OPENSEARCH_VERSION}" == "2."* || "${OPENSEARCH_VERSION}" == "3."* || "${OPENSEARCH_VERSION}" == "latest" ]]; then
            container_id=$(docker run -d -p 9200:9200 -p 9600:9600 \
                -e "discovery.type=single-node" \
                -e "DISABLE_SECURITY_PLUGIN=true" \
                -e "DISABLE_INSTALL_DEMO_CONFIG=true" \
                -e "OPENSEARCH_INITIAL_ADMIN_PASSWORD=admin" \
                "$image_name")
        else
            container_id=$(docker run -d -p 9200:9200 \
                -e "discovery.type=single-node" \
                -e "DISABLE_SECURITY_PLUGIN=true" \
                -e "DISABLE_INSTALL_DEMO_CONFIG=true" \
                "$image_name")
        fi

        if [ -z "$container_id" ]; then
            echo "Failed to start OpenSearch container!"
            return 1
        fi
        echo "Container started with ID: $container_id"
        sleep 5

        echo "Waiting for OpenSearch to start..."
        local max_wait=120
        local elapsed=0
        local success=false

        while [ $elapsed -lt $max_wait ]; do
            if curl -s "${OPENSEARCH_URL}/_cluster/health" > /dev/null 2>&1; then
                success=true
                break
            fi
            if [ $((elapsed % 15)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                echo -e "\nChecking container status at ${elapsed}s:"
                if ! docker ps | grep -q "$container_id"; then
                    echo "Container is no longer running! Here are the logs:"
                    docker logs "$container_id"
                    return 1
                fi
            fi
            echo -n "."
            sleep 1
            ((elapsed++))
        done
        echo ""

        if [ "$success" = true ]; then
            echo "OpenSearch is ready after ${elapsed} seconds!"
            OPENSEARCH_CONTAINER_ID="$container_id"
            return 0
        else
            echo "Timeout waiting for OpenSearch to start after ${max_wait} seconds!"
            echo "Final container logs:"
            docker logs "$container_id"
            return 1
        fi
    else
        echo "OpenSearch is already running"
        version_info=$(curl -s "${OPENSEARCH_URL}" | jq -r '.version | "OpenSearch \(.number) (\(.distribution // "unknown"))"')
        echo "Version info: ${version_info}"
    fi
}

create_index() {
    echo "Creating index ${INDEX_NAME} (single shard)"
    curl -s -XDELETE "${OPENSEARCH_URL}/${INDEX_NAME}" > /dev/null
    curl -s -XPUT "${OPENSEARCH_URL}/${INDEX_NAME}" \
        -H "Content-Type: application/json" \
        -d '{
            "settings": {"number_of_shards": 1, "number_of_replicas": 0},
            "mappings": {"properties": {
                "field_a": {"type": "keyword"},
                "field_b": {"type": "keyword"}
            }}
        }' > /dev/null
}

insert_test_documents() {
    # Three docs designed to isolate which clause each one matches:
    #   doc_a: matches ONLY clause-on-field_a (term field_a=alpha)
    #   doc_b: matches ONLY clause-on-field_b (term field_b=beta)
    #   doc_c: matches BOTH clauses
    echo "Inserting 3 test documents"
    curl -s -XPOST "${OPENSEARCH_URL}/${INDEX_NAME}/_bulk?refresh=true" \
        -H "Content-Type: application/x-ndjson" \
        --data-binary @- <<'EOF' > /dev/null
{"index":{"_id":"doc_a"}}
{"field_a":"alpha","field_b":"ZZZ"}
{"index":{"_id":"doc_b"}}
{"field_a":"ZZZ","field_b":"beta"}
{"index":{"_id":"doc_c"}}
{"field_a":"alpha","field_b":"beta"}
EOF
}

# Run a search and return the JSON.
# $1 = name to assign to the field_a clause
# $2 = name to assign to the field_b clause
run_search() {
    local name_a="$1"
    local name_b="$2"
    curl -s -XGET "${OPENSEARCH_URL}/${INDEX_NAME}/_search" \
        -H "Content-Type: application/json" \
        -d "{
            \"size\": 10,
            \"_source\": false,
            \"query\": {
                \"bool\": {
                    \"should\": [
                        {\"term\": {\"field_a\": {\"value\": \"alpha\", \"_name\": \"${name_a}\"}}},
                        {\"term\": {\"field_b\": {\"value\": \"beta\",  \"_name\": \"${name_b}\"}}}
                    ],
                    \"minimum_should_match\": 1
                }
            }
        }"
}

# Print one row per hit: id | matched_queries (or MISSING)
# Returns 0 if any hit is missing matched_queries, else 1.
analyze_hits() {
    local label="$1"
    local response="$2"
    echo "  --- ${label} ---"
    # Print id and matched_queries per hit; "MISSING" when the field is absent.
    echo "$response" | jq -r '
        .hits.hits[]
        | "  hit \(._id) matched_queries=\(if has("matched_queries") then (.matched_queries|tojson) else "MISSING" end)"
    '
    # Count hits missing the field.
    local missing
    missing=$(echo "$response" | jq '[.hits.hits[] | select(has("matched_queries") | not)] | length')
    echo "  hits_missing_matched_queries=${missing}"
    if [ "$missing" -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

demonstrate_bug() {
    echo
    echo "===================================================================="
    echo "Case 1: DUPLICATE _name (both clauses use _name=\"shared\")"
    echo "===================================================================="
    local dup_response
    dup_response=$(run_search "shared" "shared")
    if analyze_hits "DUP" "$dup_response"; then
        DUP_RESULT="MISSING_FIELD_OBSERVED"
    else
        DUP_RESULT="ALL_HITS_HAVE_FIELD"
    fi

    echo
    echo "===================================================================="
    echo "Case 2: DISTINCT _name (clause_a / clause_b)"
    echo "===================================================================="
    local distinct_response
    distinct_response=$(run_search "clause_a" "clause_b")
    if analyze_hits "DISTINCT" "$distinct_response"; then
        DISTINCT_RESULT="MISSING_FIELD_OBSERVED"
    else
        DISTINCT_RESULT="ALL_HITS_HAVE_FIELD"
    fi

    echo
    echo "===================================================================="
    echo "Verdict"
    echo "===================================================================="
    echo "DUP_RESULT=${DUP_RESULT}"
    echo "DISTINCT_RESULT=${DISTINCT_RESULT}"

    # Bug present: duplicate-name case drops matched_queries on at least one
    # hit, while the distinct-name control returns it on all hits.
    if [ "$DUP_RESULT" = "MISSING_FIELD_OBSERVED" ] && [ "$DISTINCT_RESULT" = "ALL_HITS_HAVE_FIELD" ]; then
        BUG_STATUS="PRESENT"
    elif [ "$DUP_RESULT" = "ALL_HITS_HAVE_FIELD" ] && [ "$DISTINCT_RESULT" = "ALL_HITS_HAVE_FIELD" ]; then
        BUG_STATUS="FIXED"
    else
        BUG_STATUS="UNEXPECTED"
    fi
    echo "BUG_STATUS=${BUG_STATUS}"
}

# Prereqs
command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
command -v jq     >/dev/null 2>&1 || { echo "jq is required"     >&2; exit 1; }

cleanup() {
    if [ -n "$OPENSEARCH_CONTAINER_ID" ]; then
        echo "Stopping OpenSearch container ${OPENSEARCH_CONTAINER_ID}"
        docker stop "$OPENSEARCH_CONTAINER_ID" >/dev/null 2>&1 || true
        docker rm   "$OPENSEARCH_CONTAINER_ID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

{
    check_opensearch
    create_index
    insert_test_documents
    demonstrate_bug
} | tee "$TEST_RESULTS_FILE"
