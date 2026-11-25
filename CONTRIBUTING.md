# Contributing

Contributions should keep these .NET Azure Functions connector samples small, independently runnable, and focused on their documented connector operations.

## Prepare and validate

Install the .NET 10 SDK. From the repository root, run:

```pwsh
dotnet restore functions-connectors-net.slnx --source https://api.nuget.org/v3/index.json -p:NuGetAudit=true -p:NuGetAuditMode=all -p:NuGetAuditLevel=low -warnaserror:NU1900,NU1901,NU1902,NU1903,NU1904
dotnet build functions-connectors-net.slnx --configuration Release --no-restore -p:EnableNETAnalyzers=true -warnaserror
```

The solution contains all 20 polling and webhook apps, including the generic samples. Keep deployment helpers under `infra/` excluded from app compilation. Follow the affected sample's README for its setup commands; polling and webhook apps have separate configuration and deployment environments.

CI builds the apps, runs the SDK analyzers, and audits direct and transitive NuGet dependencies. Separate workflows review dependency changes on PRs and run CodeQL's security-and-quality queries against the compiled C# apps. They follow the standard dependency-review pattern used by the [connector SDK](https://github.com/Azure/Connectors-NET-SDK/blob/main/.github/workflows/dependency-review.yml).

These workflows require no configured secrets or Azure credentials. CodeQL uses GitHub's automatically generated workflow token to upload results to **Security > Code scanning**, with write permission limited to its analysis job. If CodeQL default setup is already enabled, a maintainer must switch to advanced setup before using the checked-in CodeQL workflow. GitHub's built-in secret scanning is managed separately in repository settings.

CI does not deploy resources, sign in to Azure, run the Functions host, or verify live connector delivery. There are currently no automated test projects.

For a change to provisioning, authentication, or trigger handling, document the manual validation performed against an approved Azure environment and source connection, or explicitly say what was not tested. Do not create source events or enable production triggers without authorization.

## Keep changes safe and discoverable

- Never commit `local.settings.json`, `.azure/`, credentials, tokens, callback keys, Azurite state, or build outputs. Do not log raw connector payloads or source-account details.
- Use sanitized placeholders in examples, issues, and PRs. Redact tenant/account identifiers, resource IDs, callback URLs, and source data from logs and screenshots. Report suspected credential exposure privately through [Microsoft's security reporting guidance](https://www.microsoft.com/msrc).
- Keep each sample README accurate for its delivery mode, prerequisites, permissions, setup, and cleanup. Update the parent connector guide if sample paths change.
- Preserve the Learn metadata on connector-specific sample READMEs: `page_type: sample`, approved language/product slugs, descriptions under 150 characters, and unique, stable `urlFragment` values. Generic samples are intentionally not indexed.

## Submit a pull request

Open a focused PR against `main`. Explain the affected sample paths, behavior change, validation results, and any Azure/source permissions needed for manual verification. Update `CHANGELOG.md` under **Unreleased** for user-visible changes.

Microsoft may require a Contributor License Agreement for your contribution; follow the CLA bot's instructions. Respond to review feedback and let the original reviewer confirm that it is resolved.
