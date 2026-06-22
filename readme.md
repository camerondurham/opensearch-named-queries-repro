# OpenSearch Duplicate `_name` matched_queries Bug Reproduction

This status badge "passing" means the pinned OpenSearch releases still drop the `matched_queries` field on hits whose only matching clause used a duplicated `_name`.

[![Test OpenSearch Named Queries Duplicate _name Bug](https://github.com/REPLACE_ME/opensearch-named-queries-repro/actions/workflows/test-opensearch.yml/badge.svg)](https://github.com/REPLACE_ME/opensearch-named-queries-repro/actions/workflows/test-opensearch.yml)

This repo contains a deterministic 3-document test that demonstrates: when two sibling clauses in the same `bool` share the same `_name`, OpenSearch silently drops one clause at parse time, and any hit whose only matching named clause was the dropped one is returned with the `matched_queries` field entirely absent (the key is missing, not empty).

GitHub Actions currently treats `BUG_STATUS=PRESENT` as a passing result. If the behavior changes to `BUG_STATUS=FIXED`, the workflow fails intentionally so this repo can be updated to reflect the fix.

CI pins explicit OpenSearch releases instead of floating tags so the badge reflects a stable reproduction rather than upstream tag drift.

Also see:

- OpenSearch named queries documentation: https://opensearch.org/docs/latest/query-dsl/named-queries/
- Related Elasticsearch issues for the same code lineage:
  - [elastic/elasticsearch#6496](https://github.com/elastic/elasticsearch/issues/6496) - Named queries (_name) are inconsistent and the documentation is wrong
  - [elastic/elasticsearch#26417](https://github.com/elastic/elasticsearch/issues/26417) - Named queries return documents with no `matched_queries`
  - [elastic/elasticsearch#101480](https://github.com/elastic/elasticsearch/issues/101480) - Inconsistent behaviour for `matched_queries` field

## Bug Description

OpenSearch source path:

- `server/src/main/java/org/opensearch/index/query/AbstractQueryBuilder.java` reads `_name` and calls `context.addNamedQuery(name, query)` during `toQuery()`.
- `server/src/main/java/org/opensearch/index/query/QueryShardContext.java` stores named queries in `Map<String, Query> namedQueries = new HashMap<>()`. `addNamedQuery` calls `put(name, query)` - last writer wins, no error and no warning.
- `server/src/main/java/org/opensearch/search/fetch/subphase/MatchedQueriesPhase.java` iterates the surviving name -> query map per hit. The overwritten clause is never evaluated.

Effect:

- The first clause's `Query` object is silently overwritten by the second clause's `Query` object.
- Hits that only matched the overwritten (first) clause are returned with `matched_queries` absent entirely.
- This is deterministic per shard. The behavior may look intermittent at scale because top-N shard sampling varies which docs the caller actually sees.

## Running the Test

```bash
# run against a specific OpenSearch release tag
./test-named-queries-bug.sh 2.19.2
```

The script will:
- Start a single-shard OpenSearch container at the given version (or use one already on `localhost:9200`)
- Create an index with two `keyword` fields (`field_a`, `field_b`) and `number_of_shards: 1`
- Index three documents:
  - `doc_a`: `field_a=alpha`, `field_b=ZZZ` - matches clause-on-`field_a` only
  - `doc_b`: `field_a=ZZZ`, `field_b=beta` - matches clause-on-`field_b` only
  - `doc_c`: `field_a=alpha`, `field_b=beta` - matches both clauses
- Run two `bool.should` searches against those docs and print `matched_queries` per hit:
  - DUP case: both clauses use `_name="shared"`
  - DISTINCT case: clauses use `_name="clause_a"` and `_name="clause_b"`
- Set `BUG_STATUS=PRESENT|FIXED|UNEXPECTED` and write to `test-results.txt`

## Expected vs Actual Behavior

Expected (per OpenSearch documentation):

- DUP case: every hit (`doc_a`, `doc_b`, `doc_c`) should include `matched_queries: ["shared"]`.
- DISTINCT case: `doc_a` -> `["clause_a"]`, `doc_b` -> `["clause_b"]`, `doc_c` -> `["clause_a", "clause_b"]`.

Actual (in pinned CI releases):

- DUP case: `doc_a` is returned WITHOUT a `matched_queries` field at all (the key is absent, not empty). `doc_b` and `doc_c` carry `["shared"]` because the surviving registered query is the second clause and they match it.
- DISTINCT case: every hit carries the expected names. This is the control - it confirms the missing field in the DUP case is caused by the duplicate `_name` and not by anything else.
