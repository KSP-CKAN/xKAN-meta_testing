# xKAN-meta_testing

GitHub Action to validate .netkan and .ckan files in GitHub repos.

## Usage

If you are the author or maintainer of a mod that uses a [meta-netkan], you can use this Action to validate your mod's CKAN metadata. It will appear in the Actions tab of your repo on GitHub and automatically parse your .netkan file, generate a .ckan file based on the current release, and install your mod and its dependencies in a sandbox, reporting any problems it finds along the way. Note that .ckan files will be ignored in your repo because they might be [internal .ckan files] lacking enough info to inflate or validate.

[meta-netkan]: https://github.com/KSP-CKAN/CKAN/blob/master/Spec.md#ckannetkanurl
[internal .ckan files]: https://github.com/KSP-CKAN/CKAN/wiki/Adding-a-mod-to-the-CKAN#internal-ckan-files

Create a file in your repo at `.github/workflows/netkan.yml` as follows:

```yml
on:
    push:
        branches:
            - master
    pull_request:
        types:
            - opened
            - synchronize
            - reopened
jobs:
    Inflate:
        runs-on: ubuntu-latest
        steps:
            - name: Get mod repo
              uses: actions/checkout@v2
            - name: Test meta-netkans
              uses: KSP-CKAN/xKAN-meta_testing@master
              with:
                  pull request body: ${{ github.event.pull_request.body }}
```

If you're on the CKAN dev team, a few changes are needed for the main metadata repos, to make the Action search the commit history for changes:

- The checkout action needs `fetch-depth: 0` to get the full commit history
- An `actions/cache` step will save and restore the download cache from one run to the next; the key and restore-key allow previous caches to be pulled forward while still saving the latest changes at the end (but only if the validation succeeds, to ensure authors can replace downloads to fix problems).
- The `source` input needs to be `commits` to make the Action only validate files as they are changed, and validate .ckan files in addition to .netkan files

Use this for NetKAN:

```yml
on:
    push:
        branches:
            - master
    pull_request:
        types:
            - opened
            - synchronize
            - reopened
jobs:
    Inflate:
        runs-on: ubuntu-latest
        steps:
            - name: Get NetKAN repo
              uses: actions/checkout@v2
              with:
                  fetch-depth: 0
                  ref: ${{ github.event.pull_request.head.sha }}
            - name: Cache downloads
              uses: actions/cache@v2
              with:
                  path: /cache
                  key: downloads-${{ github.run_id }}
                  restore-keys: |
                      downloads-
            - name: Test modified netkans
              uses: KSP-CKAN/xKAN-meta_testing@master
              env:
                  GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
                  PR_BASE_SHA: ${{ github.event.pull_request.base.sha }}
                  EVENT_BEFORE: ${{ github.event.before }}
              with:
                  source: commits
                  pull request body: ${{ github.event.pull_request.body }}
```

CKAN-meta should use essentially the same configuration with different labels; the script handles both .netkan and .ckan files depending on what is in the repo:

```yml
on:
    push:
        branches:
            - master
    pull_request:
        types:
            - opened
            - synchronize
            - reopened
jobs:
    Validate:
        runs-on: ubuntu-latest
        steps:
            - name: Get CKAN-meta repo
              uses: actions/checkout@v2
              with:
                  fetch-depth: 0
                  ref: ${{ github.event.pull_request.head.sha }}
            - name: Cache downloads
              uses: actions/cache@v2
              with:
                  path: /cache
                  key: downloads-${{ github.run_id }}
                  restore-keys: |
                      downloads-
            - name: Test modified ckans
              uses: KSP-CKAN/xKAN-meta_testing@master
              env:
                  GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
                  PR_BASE_SHA: ${{ github.event.pull_request.base.sha }}
                  EVENT_BEFORE: ${{ github.event.before }}
              with:
                  source: commits
                  pull request body: ${{ github.event.pull_request.body }}
```

## See also

Validate your KSP-AVC .version files with https://github.com/DasSkelett/AVC-VersionFileValidator !

## Contributions

- Leon Wright
- HebaruSan

### Legacy

The previous scripts were moved over from KSP-CKAN/CKAN-meta and KSP-CKAN/NetKAN. Thanks to all the contributions from the following in no particular order.

- Matthew Heguy
- Leon Wright
- Dwayne Bent
- Willhelm Rendahl
- Paul Fenwick
- Alexander Dzhoganov
- Magnus Aagaard Sørensen
- Hakan Tandogan
- Myk Dowling
- Arne Peirs
