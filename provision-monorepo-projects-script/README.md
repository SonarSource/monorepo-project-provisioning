# Monorepo Project Provisioning

`provision-monorepo-projects.sh` bulk-provisions SonarQube Cloud projects for a monorepo in a single API call. It reads a list of project definitions from a JSON file, resolves the DevOps Platform (GitHub, Bitbucket) installation key automatically, and calls the `POST /api/alm_integration/provision_monorepo_projects` endpoint.

## Prerequisites

- [`jq`](https://jqlang.org/download/) — JSON processing
- [`curl`](https://curl.se/download.html) — HTTP requests
- A SonarQube Cloud Personal Access Token whose owner has **organization admin** permissions
- Organization key – can be found on the SonarQube Cloud organization settings page. **Important**: the SonarQube Cloud organization needs to be bound to the DevOps platform organization for this script to work.
- Repository name – the exact display name of the repository on the DevOps platform, as shown in SonarQube Cloud.

## Usage

```
./provision-monorepo-projects.sh -f <projects-file> -t <token> -o <org-key> -r <repository-name> [OPTIONS]
```

### Required flags

| Flag | Description |
|------|-------------|
| `-f <file>` | Path to JSON file with the list of projects to provision (see format below) |
| `-t <token>` | SonarQube Cloud Personal Access Token |
| `-o <org-key>` | SonarQube Cloud organization key |
| `-r <repository-name>` | Exact display name of the repository on the DevOps platform (matched against the `name` field in the `dop-repositories` API response) — used to resolve the installation key |

### Optional flags

| Flag | Default | Description |
|------|---------|-------------|
| `-u <url>` | `https://sonarcloud.io` | SonarQube Cloud base URL |
| `-n <type>` | `previous_version` | `newCodeDefinitionType` sent to the API |
| `-v <value>` | `previous_version` | `newCodeDefinitionValue` sent to the API |
| `-h` | — | Print help and exit |

## Projects file format

A JSON array of objects, each with a `projectKey` and `projectName`:

```json
[
  { "projectKey": "my-org_frontend", "projectName": "Frontend" },
  { "projectKey": "my-org_backend",  "projectName": "Backend"  }
]
```

The script validates that the file is well-formed JSON and that every entry contains both required string fields before making any API call.

## How it works

1. Checks that `jq` and `curl` are available.
2. Validates the projects JSON file structure.
3. Resolves the organization ID by calling `GET /organizations/organizations?organizationKey=<org-key>`.
4. Resolves the DevOps platform type (GitHub, Bitbucket, GitLab, Azure DevOps) by calling `GET /dop-translation/organization-bindings?organizationId=<org-id>`.
5. Calls `GET /dop-translation/dop-repositories` with `q=<repository-name>` to find the repository by its exact display name and resolve the installation key.
6. Builds the request body, injecting the resolved `installationKey` into every project entry.
7. Posts to `POST /api/alm_integration/provision_monorepo_projects` in chunks of 25 projects. If a chunk fails, retries each project individually, skipping any that already exist.

## Examples

### Basic invocation

```bash
./provision-monorepo-projects.sh \
  -f projects.json \
  -t "$SONAR_TOKEN" \
  -o my-org \
  -r "My Repository"
```

### Against a non-production environment

```bash
./provision-monorepo-projects.sh \
  -f projects.json \
  -t "$SONAR_TOKEN" \
  -o my-org \
  -r "My Repository" \
  -u https://sc-staging.io
```

## Error handling

| Situation | Exit code | Message |
|-----------|-----------|---------|
| Missing required flag | 1 | Lists which flags are missing |
| Projects file not found or invalid JSON | 1 | Describes the file problem |
| Projects file fails schema validation | 1 | Lists each invalid entry |
| Organization not found | 1 | Reports the org key that was not found |
| No DevOps platform binding found | 1 | Suggests checking the DevOps platform binding |
| `dop-repositories` HTTP error | 1 | Prints HTTP status and response body |
| Repository name not found | 1 | Reports the name that was not found |
| Provisioning API HTTP error | 1 | Prints HTTP status and response body |
