#!/usr/bin/env bash
#shopt -s extdebug     # or --debugging
set +H +o history     # disable history features (helps avoid errors from "!" in strings)
shopt -u cmdhist      # would be enabled and have no effect otherwise
shopt -s execfail     # ensure interactive and non-interactive runtime are similar
set -euET -o pipefail # put bash into strict mode & have it give descriptive errors
umask 055             # change all generated file perms from 755 to 700

# force byte-wise sorting and default langauge output
export LC_ALL=C

# fail if there are declared function names matching this program's
declare -Ft get_file_contents &>/dev/null && exit 1
declare -Ft parse_file_contents &>/dev/null && exit 1
declare -Ft handle_format_output &>/dev/null && exit 1

# https://github.com/koalaman/shellcheck/wiki/SC2155
DOWNLOADS=$(mktemp -d)
FORMAT_DOMAIN='domain'
FORMAT_IPV4='ipv4'
FORMAT_IPV4_CIDR='ipv4_cidr'
FORMAT_IPV6='ipv6'
readonly DOWNLOADS FORMAT_DOMAIN FORMAT_IPV4 FORMAT_IPV4_CIDR FORMAT_IPV6
FORMATS=("$FORMAT_IPV4" "$FORMAT_IPV4_CIDR" "$FORMAT_IPV6" "$FORMAT_DOMAIN")
readonly -a FORMATS
trap 'rm -rf "$DOWNLOADS"' EXIT || exit 1

# params: src_list
get_file_contents() {
  case $1 in
  *.tar.gz)
    # Both Shallalist and Ut-capitole adhere to this format
    # If any archives are added that do not, this line needs to change
    tar -xOzf "$1" --wildcards-match-slash --wildcards '*/domains'
    ;;
  *.zip) zcat "$1" ;;
  *.7z) 7za -y -so e "$1" ;;
  *) cat -s "$1" ;;
  esac
}

# params: engine, rule, key
parse_file_contents() {
  case $1 in
  cat) cat -s ;;
  mawk) mawk "$2" ;;
  gawk) gawk --sandbox -O -- "$2" ;;
  jq) jq -r "$2" ;;
  miller)
    if [[ $2 =~ ^[0-9]+$ ]]; then
      mlr --mmap --csv --skip-comments -N cut -f "$2"
    else
      mlr --mmap --csv --skip-comments --headerless-csv-output cut -f "$2"
    fi
    ;;
  sed) sed -n "$2" ;;
  perl)
    # https://unix.stackexchange.com/a/566565
    # https://manpages.ubuntu.com/manpages/hirsute/man3/Regexp::Common::net.3pm.html
    perl -MRegexp::Common=net -nE "$2"
    ;;
  saxon) java -cp bin/SaxonHE10-5J/saxon-he-10.5.jar net.sf.saxon.Query -config:configs/saxon.xml -s:/dev/stdin -qs:"$2" ;;
  *)
    echo "[INVALID ENGINE] { source: ${3}, element: ${1} }"
    exit 1
    ;;
  esac |
    mawk '$0!~/^$/{print $0}' | # filter blank lines
    mawk '!seen[$0]++'          # filter duplicates
}

# params: format, color, key
handle_format_output() {
  case $1 in
  domain) ./scripts/idn_to_punycode.pl >>"build/${2}_${1}.txt" ;;
  ipv4)
    while IFS= read -r line; do
      case $line in
      */*) printf "%s\n" "$line" >>"build/${2}_${1}_cidr.txt" ;; # cidr block
      *-*) ipcalc "$line" >>"build/${2}_${1}_cidr.txt" ;;        # deaggregate ip range
      *.*.*.*) printf "%s\n" "$line" >>"build/${2}_${1}.txt" ;;  # ip address
      *) echo "[INVALID IPv4]: { source: ${3}, element: ${line} }" ;;     # debug if ips are being processed well
      esac
    done
    ;;
  ipv6) cat >>"build/${2}_${1}.txt" ;;
  *)
    echo "[INVALID FORMAT] { source: ${3}, element: ${1} }"
    exit 1
    ;;
  esac
}

main() {
  local cache_dir
  local src_list
  local list

  # make the build directory if it doesn't exist
  mkdir -p build/

  for color in 'white' 'black'; do
    cache_dir="${DOWNLOADS}/${color}"

    set +e # temporarily disable strict fail, in case downloads fail
    jq -r --arg color "$color" 'to_entries[] |
        select(.value.color == $color) |
        {key, mirrors: .value.mirrors} |
        .extension = (.mirrors[0] | match(".(tar.gz|zip|7z|json)").captures[0].string // "txt") |
        (.mirrors | join("\t")), " out=\(.key).\(.extension)"' core/sources.json |
      aria2c -i- -d "$cache_dir" --conf-path='./configs/aria2.conf'
    set -e

    jq -r --arg color "$color" 'to_entries[] |
        select(.value.color == $color) |
         .key as $k | .value.filters[] | "\($k)#\(.engine)#\(.format)#\(.rule)"' core/sources.json |
      while IFS='#' read -r key engine format rule; do
        src_list=$(find -P -O3 "$cache_dir" -type f -name "$key*")

        if [ -n "$src_list" ]; then
          get_file_contents "$src_list" |
            parse_file_contents "$engine" "$rule" "$key" |
            handle_format_output "$format" "$color" "$key"
        fi
        # else the download failed and src_list is empty
      done

    for format in "${FORMATS[@]}"; do
      list="build/${color}_${format}.txt"

      if test -f "$list"; then
        checksums="build/${color}_${format}.checksums"

        parsort -u -S 99% --parallel=48 -T "$cache_dir" "$list" | sponge "$list"

        if [[ "$color" == 'black' ]]; then
          if test -f "build/white_${format}.txt"; then
            grep -Fxvf "build/white_${format}.txt" "$list" | sponge "$list"
          fi
        fi

        cat "${list}" | md5sum >>"${checksums}"
        cat "${list}" | b2sum >>"${checksums}"
        cat "${list}" | sha1sum >>"${checksums}"
        cat "${list}" | sha224sum >>"${checksums}"
        cat "${list}" | sha256sum >>"${checksums}"
        cat "${list}" | sha384sum >>"${checksums}"
        cat "${list}" | sha512sum >>"${checksums}"
      fi
    done
  done
}

# https://github.com/koalaman/shellcheck/wiki/SC2218
main

# reset the locale after processing
unset LC_ALL
