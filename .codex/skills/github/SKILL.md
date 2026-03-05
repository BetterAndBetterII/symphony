---
name: github
description: |
  Use Symphony's `github_graphql` client tool for raw GitHub GraphQL operations
  such as comment editing and GitHub Project (ProjectV2) updates.
---

# GitHub GraphQL

Use this skill for raw GitHub GraphQL work during Symphony app-server sessions.

## Primary tool

Use the `github_graphql` client tool exposed by Symphony's app-server session.
It reuses Symphony's configured GitHub auth for the session (`tracker.api_key`,
`GITHUB_TOKEN`, or `GH_TOKEN`).

Tool input:

```json
{
  "query": "query or mutation document",
  "variables": {
    "optional": "graphql variables object"
  }
}
```

Tool behavior:

- Send one GraphQL operation per tool call.
- Multi-operation documents are rejected (operationName selection is intentionally out of scope).
- Treat a top-level `errors` array as a failed GraphQL operation even if the
  tool call itself completed.
- Keep queries/mutations narrowly scoped; ask only for the fields you need.

## Discovering unfamiliar operations

Use targeted introspection through `github_graphql`:

List mutation names:

```graphql
query ListMutations {
  __type(name: "Mutation") {
    fields {
      name
    }
  }
}
```

## Common workflows

### Add a comment to a GitHub issue/PR

```graphql
mutation AddComment($subjectId: ID!, $body: String!) {
  addComment(input: { subjectId: $subjectId, body: $body }) {
    commentEdge {
      node {
        id
        url
      }
    }
  }
}
```

### Update a GitHub Project (ProjectV2) item status

1) Resolve the Project id, status field id, and option id.

```graphql
query ProjectFields($owner: String!, $number: Int!) {
  repositoryOwner(login: $owner) {
    __typename
    ... on Organization {
      projectV2(number: $number) {
        id
        fields(first: 50) {
          nodes {
            __typename
            ... on ProjectV2SingleSelectField {
              id
              name
              options {
                id
                name
              }
            }
          }
        }
      }
    }
    ... on User {
      projectV2(number: $number) {
        id
        fields(first: 50) {
          nodes {
            __typename
            ... on ProjectV2SingleSelectField {
              id
              name
              options {
                id
                name
              }
            }
          }
        }
      }
    }
  }
}
```

2) Update the item's field value.

```graphql
mutation UpdateProjectItemStatus(
  $projectId: ID!
  $itemId: ID!
  $fieldId: ID!
  $optionId: ID!
) {
  updateProjectV2ItemFieldValue(
    input: {
      projectId: $projectId
      itemId: $itemId
      fieldId: $fieldId
      value: { singleSelectOptionId: $optionId }
    }
  ) {
    projectV2Item {
      id
    }
  }
}
```

## Usage rules

- Prefer `github_graphql` for comment and ProjectV2 mutations inside a Symphony
  session to avoid ad-hoc shell auth handling.
- Use minimal queries and keep sensitive token material out of comments/logs.
