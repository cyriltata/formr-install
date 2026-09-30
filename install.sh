#!/usr/bin/env bash
# Install a formr GitHub release zip, PHP dependencies, and webpack assets.
#
# Env names map onto existing settings only. The array shape in
# config/settings.php is left as it is; matching values are replaced.
# USE_STUDY_SUBDOMAINS sets $settings['use_study_subdomains'] when that
# key exists, otherwise $settings['use']['study_subdomains'], otherwise
# $settings['use']['study']['subdomains']. DATABASE_HOST sets
# $settings['database_host'] or $settings['database']['host'].
# An existing file under config/ is never replaced by config-dist.

set -euo pipefail

REPO="https://github.com/rubenarslan/formr.org"
TOKEN=""
TAG=""
INSTALL_DIR="/var/www/formr.org"
ENV_FILE=""
TMP_DIRS=()

cleanup() {
  local d
  if [[ ${#TMP_DIRS[@]} -eq 0 ]]; then
    return 0
  fi
  for d in "${TMP_DIRS[@]}"; do
    rm -rf -- "$d"
  done
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: install-formr.sh [options]

Download a formr release zip, install PHP and webpack assets, and copy
config-dist into config when those files are not already there.
If the install directory already exists, files from the release replace
files at the same path. Files that are only in the install directory are kept.

Options:
  --repo URL          Git repository (default: https://github.com/rubenarslan/formr.org)
  --token TOKEN       GitHub token for a private repository archive
  --ghcr-token TOKEN  Same as --token. Must be allowed to read repository contents
  --tag TAG           Release tag, for example v1.11.0 (default: latest release)
  --install-dir DIR   Install directory (default: /var/www/formr.org)
  --env-file FILE     Optional env file. Matching keys fill existing config/settings.php values.
                      Omit it and edit config/settings.php after install.
  -h, --help          Show this help

Existing files in the config directory are kept. --env-file updates
matching values in config/settings.php and does not add settings keys.
EOF
}

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "Root privileges are required to install packages." >&2
    return 1
  fi
}

install_with_pkg() {
  if command -v apt-get >/dev/null 2>&1; then
    run_root apt-get update
    run_root apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then
    run_root dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    run_root yum install -y "$@"
  else
    return 1
  fi
}

ensure_package_command() {
  local cmd="$1"
  shift
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "${cmd}: $(command -v "$cmd")"
    return 0
  fi
  echo "Installing ${cmd}..."
  if ! install_with_pkg "$@"; then
    echo "Could not install ${cmd}. Install $* and re-run." >&2
    exit 1
  fi
  hash -r
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "${cmd} is still not on PATH after installation." >&2
    exit 1
  fi
}

ensure_php() {
  if command -v php >/dev/null 2>&1; then
    echo "php: $(command -v php)"
    return 0
  fi
  echo "PHP CLI is required (php >= 8.2). Install php-cli and re-run." >&2
  exit 1
}

composer_version() {
  local line
  command -v composer >/dev/null 2>&1 || return 1
  line="$(composer --version --no-ansi 2>/dev/null || true)"
  printf '%s\n' "$line" | sed -n 's/^Composer version \([0-9][0-9.]*\).*/\1/p' | head -n 1
}

composer_latest_stable() {
  curl -fsSL https://getcomposer.org/versions | php -r '
    $json = json_decode(stream_get_contents(STDIN), true);
    $version = $json["stable"][0]["version"] ?? "";
    if (!is_string($version) || preg_match("/^[0-9]+\.[0-9]+\.[0-9]+$/", $version) !== 1) {
        fwrite(STDERR, "Could not read the latest stable Composer version.\n");
        exit(1);
    }
    echo $version;
  '
}

version_at_least() {
  php -r 'exit(version_compare($argv[1], $argv[2], ">=") ? 0 : 1);' "$1" "$2"
}

install_composer_phar() {
  local work dest expected actual
  work="$(mktemp -d)"
  TMP_DIRS+=("$work")
  curl -fsSL -o "${work}/composer-setup.php" https://getcomposer.org/installer
  # The signature is published separately from the installer. getcomposer.org/installer.sig returns 404.
  expected="$(curl -fsSL https://composer.github.io/installer.sig)"
  actual="$(php -r "echo hash_file('sha384', \$argv[1]);" "${work}/composer-setup.php")"
  if [[ "$expected" != "$actual" ]]; then
    echo "Composer installer checksum did not match." >&2
    exit 1
  fi
  if [[ -w /usr/local/bin ]] || [[ "$(id -u)" -eq 0 ]]; then
    dest="/usr/local/bin"
  elif command -v sudo >/dev/null 2>&1; then
    dest="/usr/local/bin"
  else
    dest="${HOME}/.local/bin"
    mkdir -p "$dest"
  fi
  if [[ -w "$dest" ]] || [[ "$(id -u)" -eq 0 ]]; then
    php "${work}/composer-setup.php" --install-dir="$dest" --filename=composer
  else
    run_root php "${work}/composer-setup.php" --install-dir="$dest" --filename=composer
  fi
  export PATH="${dest}:${PATH}"
  hash -r
}

ensure_composer() {
  local latest installed
  ensure_php
  latest="$(composer_latest_stable)"
  installed="$(composer_version || true)"
  if [[ -n "$installed" ]] && version_at_least "$installed" "$latest"; then
    echo "composer: $(command -v composer) (${installed})"
    return 0
  fi
  if [[ -n "$installed" ]]; then
    echo "Updating composer ${installed} to ${latest}..."
  else
    echo "Installing composer ${latest}..."
  fi
  install_composer_phar
  installed="$(composer_version || true)"
  if [[ -z "$installed" ]] || ! version_at_least "$installed" "$latest"; then
    echo "Composer ${latest} or newer is required. Found ${installed:-no composer on PATH}." >&2
    exit 1
  fi
  echo "composer: $(command -v composer) (${installed})"
}

node_major_version() {
  local raw
  raw="$(node -v 2>/dev/null || true)"
  raw="${raw#v}"
  raw="${raw%%.*}"
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    echo "$raw"
  else
    echo 0
  fi
}

install_node_22() {
  local arch work sums sum file name expected actual tarball
  case "$(uname -m)" in
    x86_64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      echo "Cannot install Node.js 22 for architecture $(uname -m)." >&2
      exit 1
      ;;
  esac
  work="$(mktemp -d)"
  TMP_DIRS+=("$work")
  sums="${work}/SHASUMS256.txt"
  curl -fsSL -o "$sums" https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt
  name=""
  expected=""
  while read -r sum file; do
    if [[ "$file" == node-v22.*-linux-${arch}.tar.gz ]]; then
      name="$file"
      expected="$sum"
      break
    fi
  done < "$sums"
  if [[ -z "$name" || -z "$expected" ]]; then
    echo "Could not find a Node.js 22 linux-${arch} archive." >&2
    exit 1
  fi
  tarball="${work}/${name}"
  echo "Downloading https://nodejs.org/dist/latest-v22.x/${name}"
  curl -fsSL -o "$tarball" "https://nodejs.org/dist/latest-v22.x/${name}"
  actual="$(php -r "echo hash_file('sha256', \$argv[1]);" "$tarball")"
  if [[ "$expected" != "$actual" ]]; then
    echo "Node.js archive checksum did not match." >&2
    exit 1
  fi
  run_root tar -xzf "$tarball" -C /usr/local --strip-components=1
  export PATH="/usr/local/bin:${PATH}"
  hash -r
}

ensure_node() {
  local major=0
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    major="$(node_major_version)"
    if [[ "$major" -ge 22 ]]; then
      echo "node: $(command -v node) ($(node -v))"
      echo "npm: $(command -v npm) ($(npm -v))"
      return 0
    fi
    echo "Node.js $(node -v) is older than 22. Installing Node.js 22..."
  else
    echo "Installing Node.js 22..."
  fi
  install_node_22
  major="$(node_major_version)"
  if [[ "$major" -lt 22 ]] || ! command -v npm >/dev/null 2>&1; then
    echo "Node.js 22 or newer is required so npm can build the assets. Found node $(node -v 2>/dev/null || echo missing)." >&2
    exit 1
  fi
  echo "node: $(command -v node) ($(node -v))"
  echo "npm: $(command -v npm) ($(npm -v))"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        REPO="${2:-}"
        shift 2
        ;;
      --token|--ghcr-token)
        TOKEN="${2:-}"
        shift 2
        ;;
      --tag)
        TAG="${2:-}"
        shift 2
        ;;
      --install-dir)
        INSTALL_DIR="${2:-}"
        shift 2
        ;;
      --env-file)
        ENV_FILE="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

parse_repo() {
  local url="${REPO%/}"
  url="${url%.git}"
  if [[ "$url" =~ ^https?://github\.com/([^/]+)/([^/]+)$ ]]; then
    OWNER="${BASH_REMATCH[1]}"
    REPO_NAME="${BASH_REMATCH[2]}"
  elif [[ "$url" =~ ^git@github\.com:([^/]+)/([^/]+)$ ]]; then
    OWNER="${BASH_REMATCH[1]}"
    REPO_NAME="${BASH_REMATCH[2]}"
  else
    echo "Only GitHub repository URLs are supported: ${REPO}" >&2
    exit 1
  fi
  REPO="https://github.com/${OWNER}/${REPO_NAME}"
}

resolve_tag() {
  if [[ -n "$TAG" ]]; then
    return 0
  fi
  local url="https://api.github.com/repos/${OWNER}/${REPO_NAME}/releases/latest"
  local -a curl_args=(-fsSL -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
  if [[ -n "$TOKEN" ]]; then
    curl_args+=(-H "Authorization: Bearer ${TOKEN}")
  fi
  local body
  if ! body="$(curl "${curl_args[@]}" "$url")"; then
    echo "Could not read the latest release. Pass --tag, for example --tag v1.11.0." >&2
    exit 1
  fi
  TAG="$(printf '%s' "$body" | php -r '
    $json = json_decode(stream_get_contents(STDIN), true);
    if (!is_array($json) || empty($json["tag_name"]) || !is_string($json["tag_name"])) {
        fwrite(STDERR, "The latest-release response did not include a tag.\n");
        exit(1);
    }
    echo $json["tag_name"];
  ')"
  echo "Using latest release tag ${TAG}"
}

download_release() {
  local zip_url work archive extract src count entry http_code magic
  local -a curl_args
  # The github.com /archive/ URL returns 404 for a private repository and
  # does not accept a bearer token. The API zipball endpoint does: it
  # redirects to a short-lived codeload URL that carries the authorization.
  if [[ -n "$TOKEN" ]]; then
    zip_url="https://api.github.com/repos/${OWNER}/${REPO_NAME}/zipball/${TAG}"
  else
    zip_url="${REPO}/archive/refs/tags/${TAG}.zip"
  fi
  echo "Downloading ${zip_url}"
  work="$(mktemp -d)"
  TMP_DIRS+=("$work")
  archive="${work}/formr.zip"
  extract="${work}/src"
  mkdir -p "$extract"
  curl_args=(-sS -L --retry 3 -o "$archive" -w "%{http_code}")
  if [[ -n "$TOKEN" ]]; then
    curl_args+=(
      -H "Authorization: Bearer ${TOKEN}"
      -H "Accept: application/vnd.github+json"
      -H "X-GitHub-Api-Version: 2022-11-28"
    )
  fi
  http_code="$(curl "${curl_args[@]}" "$zip_url" || true)"
  magic="$(head -c 2 "$archive" 2>/dev/null || true)"
  if [[ "$http_code" != "200" || "$magic" != "PK" ]]; then
    echo "Could not download the release archive (HTTP ${http_code})." >&2
    if [[ -z "$TOKEN" ]]; then
      echo "If the repository is private, pass --token with a GitHub token that can read repository contents." >&2
    else
      echo "The token was sent to the GitHub API, and the archive was still refused." >&2
      echo "It needs permission to read this repository's contents (classic scope: repo, or fine-grained Contents: Read)." >&2
      echo "A token that can only pull GHCR images cannot download the source zip." >&2
    fi
    exit 1
  fi
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$archive" -d "$extract"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m zipfile -e "$archive" "$extract"
  else
    echo "Installing unzip..."
    install_with_pkg unzip
    unzip -q "$archive" -d "$extract"
  fi
  count=0
  src=""
  while IFS= read -r entry; do
    count=$((count + 1))
    src="$entry"
  done < <(find "$extract" -mindepth 1 -maxdepth 1)
  if [[ "$count" -eq 1 && -d "$src" ]]; then
    :
  else
    src="$extract"
  fi
  if [[ ! -f "${src}/composer.json" || ! -f "${src}/package.json" ]]; then
    echo "The archive does not look like a formr source release." >&2
    exit 1
  fi
  mkdir -p "$INSTALL_DIR"
  # Overlay the release onto the install directory. tar replaces files that
  # exist in the archive and leaves every other file in place.
  tar -C "$src" --exclude='./config' --exclude='./formr-crypto.key' -cf - . | tar -C "$INSTALL_DIR" -xf -
}

copy_missing_config() {
  local src="${INSTALL_DIR}/config-dist"
  local dst="${INSTALL_DIR}/config"
  local file base
  if [[ ! -d "$src" ]]; then
    echo "config-dist is missing from the release." >&2
    exit 1
  fi
  mkdir -p "$dst"
  for file in "$src"/*; do
    [[ -e "$file" ]] || continue
    base="$(basename "$file")"
    if [[ -e "${dst}/${base}" ]]; then
      echo "Keeping existing config/${base}"
    else
      cp -a "$file" "${dst}/${base}"
      echo "Copied config-dist/${base} to config/${base}"
    fi
  done
}

apply_env_settings() {
  local settings_file="$1"
  local env_file="$2"
  local php_file
  php_file="$(mktemp)"
  TMP_DIRS+=("$php_file")
  cat > "$php_file" << 'FORMR_ENV_PHP'
<?php
declare(strict_types=1);

if ($argc !== 3) {
    fwrite(STDERR, "Usage: apply-env settings.php envfile\n");
    exit(1);
}

$settingsFile = $argv[1];
$envFile = $argv[2];

try {
    $messages = apply_env_file($settingsFile, $envFile);
} catch (Throwable $e) {
    fwrite(STDERR, 'Could not update config/settings.php: ' . $e->getMessage() . "\n");
    exit(1);
}

foreach ($messages as $message) {
    echo $message, "\n";
}
exit(0);

function apply_env_file(string $settingsFile, string $envFile): array
{
    if (!is_file($settingsFile)) {
        throw new RuntimeException($settingsFile . ' does not exist');
    }
    if (!is_file($envFile)) {
        throw new RuntimeException($envFile . ' does not exist');
    }

    $parsed = parse_env_file($envFile);
    $messages = $parsed['errors'];
    $settings = load_settings_array($settingsFile);
    $updates = [];
    $labels = [];

    foreach ($parsed['vars'] as $name => $raw) {
        $path = resolve_setting_path($settings, $name);
        if ($path === null) {
            $messages[] = 'Skipped ' . $name . ': no matching setting';
            continue;
        }
        $current = setting_value($settings, $path);
        $literal = php_literal($raw, $current['value']);
        if ($literal === null) {
            $messages[] = 'Skipped ' . $name . ': value does not match the current ' . php_type_name($current['value']) . ' setting ' . render_path($path);
            continue;
        }
        $key = path_key($path);
        $updates[$key] = $literal;
        $labels[$key] = $name;
    }

    if ($updates === []) {
        return $messages;
    }

    $original = file_get_contents($settingsFile);
    if ($original === false) {
        throw new RuntimeException('Could not read ' . $settingsFile);
    }
    $writer = new SettingsEnvWriter($original, $updates);
    $rewritten = $writer->rewrite();
    foreach ($updates as $key => $_literal) {
        if (!empty($writer->applied[$key])) {
            $messages[] = 'Updated ' . render_path(explode("\0", $key));
        } elseif (!empty($writer->unchanged[$key])) {
            $messages[] = 'Already set ' . render_path(explode("\0", $key));
        } else {
            $messages[] = 'Skipped ' . $labels[$key] . ': matching setting could not be updated in place';
        }
    }
    if ($rewritten !== $original) {
        $tmp = $settingsFile . '.tmp.' . getmypid();
        if (file_put_contents($tmp, $rewritten) === false) {
            throw new RuntimeException('Could not write ' . $settingsFile);
        }
        $mode = fileperms($settingsFile);
        if (!rename($tmp, $settingsFile)) {
            @unlink($tmp);
            throw new RuntimeException('Could not replace ' . $settingsFile);
        }
        if ($mode !== false) {
            chmod($settingsFile, $mode & 0777);
        }
    }
    return $messages;
}

function load_settings_array(string $file): array
{
    if (!defined('APPLICATION_ROOT')) {
        define('APPLICATION_ROOT', dirname($file, 2) . DIRECTORY_SEPARATOR);
    }
    if (!defined('CURLOPT_SSL_VERIFYPEER')) {
        define('CURLOPT_SSL_VERIFYPEER', 64);
    }
    if (!defined('CURLOPT_SSL_VERIFYHOST')) {
        define('CURLOPT_SSL_VERIFYHOST', 81);
    }
    $loader = static function (string $file): array {
        $settings = [];
        include $file;
        return $settings;
    };
    return $loader($file);
}

function parse_env_file(string $file): array
{
    $lines = file($file, FILE_IGNORE_NEW_LINES);
    if ($lines === false) {
        throw new RuntimeException('Could not read ' . $file);
    }
    $vars = [];
    $errors = [];
    foreach ($lines as $number => $line) {
        if ($number === 0) {
            $line = preg_replace('/^\xEF\xBB\xBF/', '', $line) ?? $line;
        }
        $trim = trim($line);
        if ($trim === '' || str_starts_with($trim, '#')) {
            continue;
        }
        if (str_starts_with($trim, 'export ')) {
            $trim = trim(substr($trim, 7));
        }
        if (preg_match('/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/', $trim, $matches) !== 1) {
            $errors[] = 'Skipped env line ' . ($number + 1) . ': invalid syntax';
            continue;
        }
        $vars[$matches[1]] = unquote_env_value($matches[2]);
    }
    return ['vars' => $vars, 'errors' => $errors];
}

function unquote_env_value(string $value): string
{
    $value = trim($value);
    if ($value === '') {
        return '';
    }
    $quote = $value[0];
    if (($quote === '"' || $quote === "'") && str_ends_with($value, $quote) && strlen($value) >= 2) {
        $inner = substr($value, 1, -1);
        if ($quote === '"') {
            return stripcslashes($inner);
        }
        return str_replace(["\\'", '\\\\'], ["'", '\\'], $inner);
    }
    $uncommented = preg_replace('/\s+#.*$/', '', $value);
    return rtrim($uncommented ?? $value);
}

function resolve_setting_path(array $settings, string $envKey): ?array
{
    $parts = array_values(array_filter(explode('_', strtolower($envKey)), static function (string $part): bool {
        return $part !== '';
    }));
    if ($parts === []) {
        return null;
    }

    $seen = [];
    foreach (left_peel_paths($parts) as $path) {
        $seen[path_key($path)] = true;
        if (path_is_scalar_setting($settings, $path)) {
            return $path;
        }
    }
    if (count($parts) > 12) {
        return null;
    }

    $extra = all_partitions($parts);
    usort($extra, static function (array $a, array $b): int {
        $count = count($a) <=> count($b);
        if ($count !== 0) {
            return $count;
        }
        $max = max(count($a), count($b));
        for ($i = 0; $i < $max; $i++) {
            $length = strlen($b[$i] ?? '') <=> strlen($a[$i] ?? '');
            if ($length !== 0) {
                return $length;
            }
        }
        return 0;
    });
    foreach ($extra as $path) {
        $key = path_key($path);
        if (isset($seen[$key])) {
            continue;
        }
        if (path_is_scalar_setting($settings, $path)) {
            return $path;
        }
    }
    return null;
}

function left_peel_paths(array $parts): array
{
    $paths = [];
    $count = count($parts);
    for ($i = 0; $i < $count; $i++) {
        $path = array_slice($parts, 0, $i);
        $path[] = implode('_', array_slice($parts, $i));
        $paths[] = $path;
    }
    return $paths;
}

function all_partitions(array $parts): array
{
    $paths = [];
    $walk = static function (int $start, array $prefix) use (&$walk, &$paths, $parts): void {
        $count = count($parts);
        if ($start === $count) {
            $paths[] = $prefix;
            return;
        }
        for ($end = $start + 1; $end <= $count; $end++) {
            $next = $prefix;
            $next[] = implode('_', array_slice($parts, $start, $end - $start));
            $walk($end, $next);
        }
    };
    $walk(0, []);
    return $paths;
}

function path_is_scalar_setting(array $settings, array $path): bool
{
    $found = setting_value($settings, $path);
    return $found['found'] && !is_array($found['value']);
}

function setting_value(array $settings, array $path): array
{
    $cursor = $settings;
    foreach ($path as $segment) {
        if (!is_array($cursor) || !array_key_exists($segment, $cursor)) {
            return ['found' => false, 'value' => null];
        }
        $cursor = $cursor[$segment];
    }
    return ['found' => true, 'value' => $cursor];
}

function php_literal(string $raw, $current): ?string
{
    if (is_bool($current)) {
        $parsed = filter_var($raw, FILTER_VALIDATE_BOOLEAN, FILTER_NULL_ON_FAILURE);
        if ($parsed === null) {
            return null;
        }
        return $parsed ? 'true' : 'false';
    }
    if (is_int($current)) {
        if (preg_match('/^-?\d+$/', $raw) !== 1) {
            return null;
        }
        return (string) (int) $raw;
    }
    if (is_float($current)) {
        $normalized = ltrim($raw, '+');
        if (preg_match('/^-?\d+(\.\d+)?([eE][+-]?\d+)?$/', $normalized) !== 1) {
            return null;
        }
        return $normalized;
    }
    if (preg_match('/^null$/i', $raw) === 1 && !is_string($current)) {
        return 'null';
    }
    return var_export($raw, true);
}

function php_type_name($current): string
{
    if (is_bool($current)) {
        return 'boolean';
    }
    if (is_int($current)) {
        return 'integer';
    }
    if (is_float($current)) {
        return 'float';
    }
    if ($current === null) {
        return 'null';
    }
    return 'string';
}

function path_key(array $path): string
{
    return implode("\0", $path);
}

function render_path(array $path): string
{
    $out = '$settings';
    foreach ($path as $segment) {
        $out .= '[' . var_export($segment, true) . ']';
    }
    return $out;
}

function unquote_php_string(string $token): string
{
    $quote = $token[0];
    $inner = substr($token, 1, -1);
    if ($quote === "'") {
        return str_replace(["\\\\", "\\'"], ["\\", "'"], $inner);
    }
    return stripcslashes($inner);
}

final class SettingsEnvWriter
{
    private array $tokens;
    private int $n;
    private int $i = 0;
    private string $out = '';
    /** @var array<string, string> */
    private array $updates;
    /** @var array<string, bool> */
    public array $applied = [];
    /** @var array<string, bool> */
    public array $unchanged = [];

    public function __construct(string $code, array $updates)
    {
        $this->tokens = token_get_all($code);
        $this->n = count($this->tokens);
        $this->updates = $updates;
    }

    public function rewrite(): string
    {
        while ($this->i < $this->n) {
            $assignment = $this->peekAssignment($this->i);
            if ($assignment === null) {
                $this->out .= $this->text($this->i);
                $this->i++;
                continue;
            }
            while ($this->i < $assignment['valueStart']) {
                $this->out .= $this->text($this->i);
                $this->i++;
            }
            $this->writeValue($assignment['path']);
        }
        return $this->out;
    }

    private function writeValue(array $prefix): void
    {
        $this->emitIgnorable();
        if ($this->i >= $this->n) {
            throw new RuntimeException('Unexpected end of settings file');
        }
        if ($this->isArrayStart($this->i)) {
            $this->writeArray($prefix);
            return;
        }
        $end = $this->expressionEnd($this->i);
        if ($end === $this->i) {
            throw new RuntimeException('Empty setting value near line ' . $this->line($this->i));
        }
        $key = path_key($prefix);
        if (isset($this->updates[$key])) {
            $span = '';
            for ($cursor = $this->i; $cursor < $end; $cursor++) {
                $span .= $this->text($cursor);
            }
            $this->out .= $this->updates[$key];
            if (trim($span) === $this->updates[$key]) {
                $this->unchanged[$key] = true;
            } else {
                $this->applied[$key] = true;
            }
            $this->i = $end;
            return;
        }
        while ($this->i < $end) {
            $this->out .= $this->text($this->i);
            $this->i++;
        }
    }

    private function writeArray(array $prefix): void
    {
        $startLine = $this->line($this->i);
        if ($this->id($this->i) === T_ARRAY) {
            $this->out .= $this->text($this->i);
            $this->i++;
            $this->emitIgnorable();
            if ($this->i >= $this->n || $this->text($this->i) !== '(') {
                throw new RuntimeException("Expected '(' after array near line {$startLine}");
            }
            $this->out .= $this->text($this->i);
            $this->i++;
            $close = ')';
        } else {
            $this->out .= $this->text($this->i);
            $this->i++;
            $close = ']';
        }

        while ($this->i < $this->n) {
            $guard = $this->i;
            $this->emitIgnorable();
            if ($this->i >= $this->n) {
                throw new RuntimeException("Unclosed array near line {$startLine}");
            }
            if ($this->text($this->i) === $close) {
                $this->out .= $this->text($this->i);
                $this->i++;
                return;
            }
            $keyInfo = $this->tryReadArrayKey($this->i);
            if ($keyInfo !== null) {
                while ($this->i < $keyInfo['valueStart']) {
                    $this->out .= $this->text($this->i);
                    $this->i++;
                }
                $child = $prefix;
                $child[] = $keyInfo['name'];
                $this->writeValue($child);
            } else {
                $end = $this->expressionEnd($this->i);
                if ($end === $this->i) {
                    throw new RuntimeException("Could not read array entry near line {$startLine}");
                }
                while ($this->i < $end) {
                    $this->out .= $this->text($this->i);
                    $this->i++;
                }
            }
            $this->emitIgnorable();
            if ($this->i < $this->n && $this->text($this->i) === ',') {
                $this->out .= $this->text($this->i);
                $this->i++;
                continue;
            }
            if ($this->i < $this->n && $this->text($this->i) === $close) {
                $this->out .= $this->text($this->i);
                $this->i++;
                return;
            }
            if ($this->i === $guard) {
                throw new RuntimeException("Could not parse settings.php near line {$startLine}");
            }
        }
        throw new RuntimeException("Unclosed array near line {$startLine}");
    }

    private function tryReadArrayKey(int $index): ?array
    {
        if ($index >= $this->n) {
            return null;
        }
        $id = $this->id($index);
        if ($id === T_CONSTANT_ENCAPSED_STRING) {
            $name = unquote_php_string($this->text($index));
        } elseif ($id === T_STRING || $id === T_LNUMBER) {
            $name = $this->text($index);
        } else {
            return null;
        }
        $arrow = $this->skipWsIndex($index + 1);
        if ($arrow >= $this->n || $this->text($arrow) !== '=>') {
            return null;
        }
        return ['name' => $name, 'valueStart' => $arrow + 1];
    }

    private function peekAssignment(int $index): ?array
    {
        if ($this->id($index) !== T_VARIABLE || $this->text($index) !== '$settings') {
            return null;
        }
        $cursor = $index + 1;
        $path = [];
        while (true) {
            $cursor = $this->skipWsIndex($cursor);
            if ($cursor >= $this->n || $this->text($cursor) !== '[') {
                break;
            }
            $cursor++;
            $cursor = $this->skipWsIndex($cursor);
            if ($cursor >= $this->n || $this->id($cursor) !== T_CONSTANT_ENCAPSED_STRING) {
                return null;
            }
            $path[] = unquote_php_string($this->text($cursor));
            $cursor++;
            $cursor = $this->skipWsIndex($cursor);
            if ($cursor >= $this->n || $this->text($cursor) !== ']') {
                return null;
            }
            $cursor++;
        }
        if ($path === []) {
            return null;
        }
        $cursor = $this->skipWsIndex($cursor);
        if ($cursor >= $this->n || $this->text($cursor) !== '=') {
            return null;
        }
        return ['path' => $path, 'valueStart' => $cursor + 1];
    }

    private function expressionEnd(int $index): int
    {
        $start = $index;
        $depth = 0;
        while ($index < $this->n) {
            $id = $this->id($index);
            $text = $this->text($index);
            if ($id === T_START_HEREDOC) {
                $index++;
                while ($index < $this->n && $this->id($index) !== T_END_HEREDOC) {
                    $index++;
                }
                if ($index < $this->n) {
                    $index++;
                }
                continue;
            }
            if ($depth === 0 && ($text === ',' || $text === ';' || $text === ')' || $text === ']')) {
                while ($index > $start && $this->isIgnorable($index - 1)) {
                    $index--;
                }
                return $index;
            }
            if ($text === '(' || $text === '[' || $text === '{') {
                $depth++;
            } elseif ($text === ')' || $text === ']' || $text === '}') {
                if ($depth === 0) {
                    return $index;
                }
                $depth--;
            }
            $index++;
        }
        return $index;
    }

    private function isArrayStart(int $index): bool
    {
        return $this->id($index) === T_ARRAY || $this->text($index) === '[';
    }

    private function emitIgnorable(): void
    {
        while ($this->i < $this->n && $this->isIgnorable($this->i)) {
            $this->out .= $this->text($this->i);
            $this->i++;
        }
    }

    private function skipWsIndex(int $index): int
    {
        while ($index < $this->n && $this->isIgnorable($index)) {
            $index++;
        }
        return $index;
    }

    private function isIgnorable(int $index): bool
    {
        $id = $this->id($index);
        return $id === T_WHITESPACE || $id === T_COMMENT || $id === T_DOC_COMMENT;
    }

    private function id(int $index): ?int
    {
        $token = $this->tokens[$index];
        return is_array($token) ? $token[0] : null;
    }

    private function text(int $index): string
    {
        $token = $this->tokens[$index];
        return is_array($token) ? $token[1] : $token;
    }

    private function line(int $index): int
    {
        $token = $this->tokens[$index];
        return is_array($token) && isset($token[2]) ? (int) $token[2] : 0;
    }
}
FORMR_ENV_PHP
  php "$php_file" "$settings_file" "$env_file"
}

main() {
  parse_args "$@"
  if [[ -z "$REPO" || -z "$INSTALL_DIR" ]]; then
    echo "--repo and --install-dir must not be empty." >&2
    exit 1
  fi
  if [[ "$INSTALL_DIR" != /* ]]; then
    INSTALL_DIR="$(pwd)/${INSTALL_DIR}"
  fi
  if [[ "$INSTALL_DIR" == "/" ]]; then
    echo "Refusing to install into /." >&2
    exit 1
  fi
  if [[ -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR" ]]; then
    echo "Install path ${INSTALL_DIR} exists and is not a directory." >&2
    exit 1
  fi
  if [[ -d "$INSTALL_DIR" ]]; then
    echo "Install directory ${INSTALL_DIR} already exists. Files from the release replace files at the same path. Files that are only in this directory are kept."
  fi
  if [[ -n "$TAG" && ! "$TAG" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Invalid tag: ${TAG}" >&2
    exit 1
  fi
  if [[ "$TOKEN" == *$'\n'* ]]; then
    echo "The token must be a single line." >&2
    exit 1
  fi
  if [[ -n "$ENV_FILE" && ! -f "$ENV_FILE" ]]; then
    echo "Env file not found: ${ENV_FILE}" >&2
    exit 1
  fi

  parse_repo
  ensure_php
  ensure_package_command curl curl
  ensure_composer
  ensure_node
  ensure_package_command git git
  resolve_tag
  if [[ ! "$TAG" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Invalid tag: ${TAG}" >&2
    exit 1
  fi

  download_release

  echo "Installing PHP dependencies..."
  (
    cd "$INSTALL_DIR"
    composer install --no-interaction --prefer-dist --no-dev
  )

  echo "Installing JavaScript dependencies..."
  (
    cd "$INSTALL_DIR"
    npm install
  )

  echo "Building assets with webpack..."
  (
    cd "$INSTALL_DIR"
    npm run webpack:build
  )

  local settings_existed=0
  if [[ -f "${INSTALL_DIR}/config/settings.php" ]]; then
    settings_existed=1
  fi
  copy_missing_config
  if [[ -n "$ENV_FILE" ]]; then
    apply_env_settings "${INSTALL_DIR}/config/settings.php" "$ENV_FILE"
  fi

  cat <<EOF

Installed formr ${TAG} in ${INSTALL_DIR}

Edit ${INSTALL_DIR}/config/settings.php before serving the site.
Set the database credentials, domains, email, and OpenCPU URLs.
EOF
  if [[ "$settings_existed" -eq 1 ]]; then
    echo "config/settings.php was already present and was left in place."
  fi
  if [[ -n "$ENV_FILE" ]]; then
    echo "Matching values from ${ENV_FILE} were written into config/settings.php."
    echo "Settings with no matching env entry were left as they are."
  fi
}

# A downloaded pipe (`curl … | bash -s --`) leaves BASH_SOURCE empty.
# Sourcing this file still skips main, because BASH_SOURCE is set and differs from $0.
if [[ ${#BASH_SOURCE[@]} -eq 0 || "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  main "$@"
fi
