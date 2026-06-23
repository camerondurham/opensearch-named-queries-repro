# OpenSearch Duplicate `_name` matched_queries Reproduction

[![Test OpenSearch Named Queries Duplicate _name](https://github.com/camerondurham/opensearch-named-queries-repro/actions/workflows/test-opensearch.yml/badge.svg)](https://github.com/REPLACE_ME/opensearch-named-queries-repro/actions/workflows/test-opensearch.yml)

When two sibling clauses in the same `bool` query share the same `_name`, OpenSearch silently drops one clause at parse time. Any hit whose only matching named clause was the dropped one comes back with the `matched_queries` field entirely absent (the key is missing, not empty).

A passing badge means the pinned OpenSearch releases still exhibit this bug. CI treats `BUG_STATUS=PRESENT` as success; if behavior changes to `BUG_STATUS=FIXED` the workflow fails intentionally so this repo can be updated. Releases are pinned (not floating tags) so the badge reflects a stable reproduction.

Also see:

- OpenSearch named queries docs: https://opensearch.org/docs/latest/query-dsl/named-queries/
- Elasticsearch issues describing this exact duplicate-`_name` drop (same code lineage):
  - [elastic/elasticsearch#26417](https://github.com/elastic/elasticsearch/issues/26417) - Named queries return documents with no `matched_queries`
  - [elastic/elasticsearch#101480](https://github.com/elastic/elasticsearch/issues/101480) - Inconsistent behaviour for `matched_queries` field
- Broader `_name` inconsistencies (different subject - parser placement / which queries accept `_name`, not the duplicate-name drop):
  - [elastic/elasticsearch#6496](https://github.com/elastic/elasticsearch/issues/6496) - Named queries (_name) are inconsistent and the documentation is wrong

## Bug Description

OpenSearch source path:

- `AbstractQueryBuilder.java` reads `_name` and calls `context.addNamedQuery(name, query)` during `toQuery()`.
- `QueryShardContext.java` stores named queries in a `HashMap<String, Query>`. `addNamedQuery` does `put(name, query)` - last writer wins, no error or warning.
- `MatchedQueriesPhase.java` iterates the surviving name -> query map per hit, so the overwritten clause is never evaluated.

The first clause's `Query` is silently overwritten by the second's, so hits that only matched the overwritten clause return without `matched_queries`. This is deterministic per shard, but can look intermittent at scale because top-N shard sampling varies which docs the caller sees.

## Running the Test

```bash
# run against a specific OpenSearch release tag
./test-named-queries-bug.sh 2.19.2
```

The script starts a single-shard OpenSearch container at the given version (or reuses one on `localhost:9200`), creates an index with two `keyword` fields (`field_a`, `field_b`), and indexes three docs:

- `doc_a`: `field_a=alpha`, `field_b=ZZZ` - matches the `field_a` clause only
- `doc_b`: `field_a=ZZZ`, `field_b=beta` - matches the `field_b` clause only
- `doc_c`: `field_a=alpha`, `field_b=beta` - matches both clauses

It then runs two `bool.should` searches and prints `matched_queries` per hit:

- DUP: both clauses use `_name="shared"`
- DISTINCT: clauses use `_name="clause_a"` and `_name="clause_b"`

Results are written to `test-results.txt` with `BUG_STATUS=PRESENT|FIXED|UNEXPECTED`.

## Expected vs Actual Behavior

Expected (per OpenSearch docs):

- DUP: every hit includes `matched_queries: ["shared"]`.
- DISTINCT: `doc_a` -> `["clause_a"]`, `doc_b` -> `["clause_b"]`, `doc_c` -> `["clause_a", "clause_b"]`.

Actual (in pinned CI releases):

- DUP: `doc_a` comes back WITHOUT a `matched_queries` field. `doc_b` and `doc_c` carry `["shared"]` because the surviving query is the second clause, which they match.
- DISTINCT: every hit carries the expected names. This control confirms the missing field in the DUP case is caused by the duplicate `_name`.

The missing-key property holds regardless of serialization form: on 2.19.2/3.1.0 with `include_named_queries_score=true`, `matched_queries` serializes as an object of name -> score rather than an array, but both forms are gated on a non-empty match set, so the key is still omitted entirely for hits with no surviving named match. (1.3.20 predates the score option and always uses the array form.)
