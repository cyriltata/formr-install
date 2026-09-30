# formr install

`install.sh` installs a [formr](https://github.com/rubenarslan/formr.org) release on a host that runs formr on its own, with the database, OpenCPU, or both on other machines.

The script downloads a GitHub release, installs PHP and JavaScript dependencies, builds the webpack assets, and copies missing files from `config-dist` into `config`. It does not install MySQL, OpenCPU, or a web server. Those stay where they already run. Set the database, OpenCPU URLs, domains, and email in `config/settings.php` after install. `--env-file` is an optional way to write those values during install.

## Requirements

- bash
- PHP CLI 8.2 or newer (`php` on `PATH`). The script does not install PHP.
- root, or sudo, so it can install `curl`, `git`, `unzip`, Node.js, and Composer when they are missing or too old
- Node.js 22 or newer, which provides `npm`. The script installs the latest Node.js 22 release when `node` or `npm` is missing, or when Node.js is older than 22
- an install directory. If it already exists, files from the release replace files at the same path, and files that are only in that directory are kept
- a reachable MySQL server and OpenCPU instance
- network access to GitHub (and to the GitHub API when you pass a token)

Composer is installed or updated to the latest stable release.

## Parameters

| Option | Required | Default | Purpose |
| --- | --- | --- | --- |
| `--env-file FILE` | No | none | Optional env file whose keys overwrite matching values in `config/settings.php`. Skip it and edit `config/settings.php` after install. |
| `--install-dir DIR` | No | `/var/www/formr.org` | Directory to install into. An existing directory is updated in place: release files replace files at the same path, and other files there are kept. Relative paths are resolved from the current directory. `/` is refused. |
| `--repo URL` | No | `https://github.com/rubenarslan/formr.org` | GitHub repository. `https://github.com/owner/name` and `git@github.com:owner/name` are accepted. |
| `--tag TAG` | No | latest release | Release tag, for example `v1.11.0`. Letters, digits, `.`, `_`, and `-` only. |
| `--token TOKEN` | **Yes** when the repository is private | none | GitHub token that can read repository contents. Classic scope `repo`, or a fine-grained token with Contents: Read. A token that can only pull GHCR images cannot download the source zip. |
| `--ghcr-token TOKEN` | Same as `--token` | none | Alias of `--token`. |
| `-h`, `--help` | No | | Print the usage text and exit. |

`--repo` and `--install-dir` may be omitted. If you pass either one, the value must not be empty.

`--env-file` may be omitted. The install copies `config-dist` into `config`, and you then set the database, OpenCPU URLs, domains, and email in `config/settings.php`. When `--env-file` is passed, the script updates only settings that already exist in `settings.php`. It does not add keys.

## Env file

This step is optional. To write settings during install, download the sample from [formr-install](https://github.com/cyriltata/formr-install/) and edit the hosts before you run the script:

```bash
curl -fsSL -o .env.sample https://raw.githubusercontent.com/cyriltata/formr-install/main/.env.sample
cp .env.sample .env
```

`.env` holds passwords and is listed in `.gitignore`. Keep it off the formr host's web root.

Set at least the database and OpenCPU values to the machines formr should use:

```bash
DATABASE_HOST="db.example.com"
DATABASE_PORT=3306
DATABASE_LOGIN="formr"
DATABASE_PASSWORD="password"
DATABASE_DATABASE="formr"

OPENCPU_INSTANCE_LOCAL_URL="https://opencpu.example.com"
OPENCPU_INSTANCE_PUBLIC_URL="https://opencpu.example.com"
```

`DATABASE_HOST` is written to `$settings['database_host']` or `$settings['database']['host']`, whichever key already exists. `true`, `false`, and `null` are written as those PHP values. A value whose type does not match the current setting is skipped. Keys that cannot be named as env variables (colon keys, list values, `2fa`, `CURLOPT_*`) stay in `settings.php` and are listed at the top of `.env.sample`.

Also set `ADMIN_DOMAIN`, `STUDY_DOMAIN`, `PROTOCOL`, and the `EMAIL_*` values in that file, or set the same values later in `config/settings.php`.

## Examples

Each example is one command. It downloads `install.sh` from [formr-install](https://github.com/cyriltata/formr-install/) and runs it. Arguments after `--` are the script parameters.

Latest public release. Edit `config/settings.php` after install:

```bash
curl -fsSL https://raw.githubusercontent.com/cyriltata/formr-install/main/install.sh | sudo bash -s -- --install-dir /var/www/formr.org
```

The same install, with settings taken from an env file:

```bash
curl -fsSL https://raw.githubusercontent.com/cyriltata/formr-install/main/install.sh | sudo bash -s -- --env-file .env --install-dir /var/www/formr.org
```

A pinned release in another directory:

```bash
curl -fsSL https://raw.githubusercontent.com/cyriltata/formr-install/main/install.sh | sudo bash -s -- --tag v1.11.0 --install-dir /srv/formr
```

A private repository. `--token` is required here:

```bash
curl -fsSL https://raw.githubusercontent.com/cyriltata/formr-install/main/install.sh | sudo bash -s -- --repo https://github.com/my-org/formr.org --token "$GITHUB_TOKEN" --tag v1.11.0 --install-dir /var/www/formr.org
```

`--ghcr-token` is the same flag:

```bash
curl -fsSL https://raw.githubusercontent.com/cyriltata/formr-install/main/install.sh | sudo bash -s -- --ghcr-token "$GITHUB_TOKEN" --install-dir /var/www/formr.org
```

## What the script does

1. Resolves the release tag (latest, unless `--tag` is set) and downloads the zip.
2. Copies the release into the install directory. Files from the release replace files at the same path. Files that are only in the install directory are kept.
3. Runs `composer install --no-interaction --prefer-dist --no-dev`.
4. Runs `npm install` and `npm run webpack:build`.
5. Copies each file from `config-dist` into `config` only when that file is not already there. Existing config files, including `settings.php`, are kept.
6. When `--env-file` is set, rewrites matching values in `config/settings.php`.

The release archive's `config` directory and `formr-crypto.key` are not copied into the install directory.

## After install

The script prints the install path and reminds you to review `config/settings.php` before serving the site. Point your web server at the formr web root in that directory, and confirm the formr host can open MySQL on `DATABASE_HOST` and both OpenCPU URLs.
