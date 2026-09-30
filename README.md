# formr install

`install.sh` installs a [formr](https://github.com/rubenarslan/formr.org) release on a host that runs formr on its own, with the database, OpenCPU, or both on other machines.

The script downloads a GitHub release, installs PHP and JavaScript dependencies, builds the webpack assets, copies missing files from `config-dist` into `config`, and writes matching values from an env file into `config/settings.php`. It does not install MySQL, OpenCPU, or a web server. Those stay where they already run. Point formr at them with `--env-file`.

## Requirements

- bash
- PHP CLI 8.2 or newer (`php` on `PATH`). The script does not install PHP.
- root, or sudo, so it can install `curl`, `git`, `npm`, and `unzip` when they are missing
- an install directory that does not exist yet, or exists and is empty
- a reachable MySQL server and OpenCPU instance
- network access to GitHub (and to the GitHub API when you pass a token)

Composer is installed automatically when it is not already on `PATH`.

## Parameters

| Option | Required | Default | Purpose |
| --- | --- | --- | --- |
| `--env-file FILE` | **Yes**, for a remote database or OpenCPU | none | Env file whose keys overwrite matching values in `config/settings.php` |
| `--install-dir DIR` | No | `/var/www/formr.org` | Directory to install into. Must be missing or empty. Relative paths are resolved from the current directory. `/` is refused. |
| `--repo URL` | No | `https://github.com/rubenarslan/formr.org` | GitHub repository. `https://github.com/owner/name` and `git@github.com:owner/name` are accepted. |
| `--tag TAG` | No | latest release | Release tag, for example `v1.11.0`. Letters, digits, `.`, `_`, and `-` only. |
| `--token TOKEN` | **Yes** when the repository is private | none | GitHub token that can read repository contents. Classic scope `repo`, or a fine-grained token with Contents: Read. A token that can only pull GHCR images cannot download the source zip. |
| `--ghcr-token TOKEN` | Same as `--token` | none | Alias of `--token`. |
| `-h`, `--help` | No | | Print the usage text and exit. |

`--repo` and `--install-dir` may be omitted. If you pass either one, the value must not be empty.

`--env-file` is the parameter that matters for this setup. Without it the install still completes, and `config/settings.php` keeps the `config-dist` defaults, which point at a local database. With it, the script updates only settings that already exist in `settings.php`. It does not add keys.

## Env file

Copy the sample and edit the hosts before you run the script:

```bash
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

Also set `ADMIN_DOMAIN`, `STUDY_DOMAIN`, `PROTOCOL`, and the `EMAIL_*` values before you serve the site.

## Examples

Remote database and OpenCPU, latest public release, default install path:

```bash
sudo ./install.sh \
  --env-file .env \
  --install-dir /var/www/formr.org
```

A pinned release in another directory:

```bash
sudo ./install.sh \
  --tag v1.11.0 \
  --install-dir /srv/formr \
  --env-file /etc/formr.env
```

A private repository. `--token` is required here:

```bash
sudo ./install.sh \
  --repo https://github.com/my-org/formr.org \
  --token "$GITHUB_TOKEN" \
  --tag v1.11.0 \
  --install-dir /var/www/formr.org \
  --env-file .env
```

`--ghcr-token` is the same flag:

```bash
sudo ./install.sh --ghcr-token "$GITHUB_TOKEN" --env-file .env
```

## What the script does

1. Checks that the install directory is missing or empty.
2. Resolves the release tag (latest, unless `--tag` is set) and downloads the zip.
3. Runs `composer install --no-interaction --prefer-dist --no-dev`.
4. Runs `npm install` and `npm run webpack:build`.
5. Copies each file from `config-dist` into `config` only when that file is not already there. Existing config files, including `settings.php`, are kept.
6. When `--env-file` is set, rewrites matching values in `config/settings.php`.

The release archive's `config` directory and `formr-crypto.key` are not copied into the install directory.

## After install

The script prints the install path and reminds you to review `config/settings.php` before serving the site. Point your web server at the formr web root in that directory, and confirm the formr host can open MySQL on `DATABASE_HOST` and both OpenCPU URLs.
