#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
fi
versions=( "${versions[@]%/}" )

releasesPage="$(curl -fsSL 'https://www.ruby-lang.org/en/downloads/releases/')"
newsPage="$(curl -fsSL 'https://www.ruby-lang.org/en/news/')" # occasionally, releases don't show up on the Releases page (see https://github.com/ruby/www.ruby-lang.org/blob/master/_data/releases.yml)
# TODO consider parsing https://github.com/ruby/www.ruby-lang.org/blob/master/_data/downloads.yml as well

latest_gem_version() {
	curl -fsSL "https://rubygems.org/api/v1/gems/$1.json" | sed -r 's/^.*"version":"([^"]+)".*$/\1/'
}

# https://github.com/docker-library/ruby/issues/246
rubygems='3.0.3'
declare -A newEnoughRubygems=(
#	[2.6]=1 # 2.6.1 => gems 3.0.1
)
# TODO once all versions are in this family of "new enough", remove RUBYGEMS_VERSION code entirely

travisEnv=
for version in "${versions[@]}"; do
	rcGrepV='-v'
	rcVersion="${version%-rc}"
	if [ "$rcVersion" != "$version" ]; then
		rcGrepV=
	fi

	IFS=$'\n'; allVersions=( $(
		curl -fsSL --compressed "https://cache.ruby-lang.org/pub/ruby/$rcVersion/" \
			| grep -oE '["/]ruby-'"$rcVersion"'.[^"]+\.tar\.xz' \
			| sed -r 's!^["/]ruby-([^"]+)[.]tar[.]xz!\1!' \
			| grep $rcGrepV -E 'preview|rc' \
			| sort -ruV
	) ); unset IFS

	fullVersion=
	shaVal=
	for tryVersion in "${allVersions[@]}"; do
		if \
			{
				versionReleasePage="$(echo "$releasesPage" | grep "<td>Ruby $tryVersion</td>" -A 2 | awk -F '"' '$1 == "<td><a href=" { print $2; exit }')" \
					&& [ "$versionReleasePage" ] \
					&& shaVal="$(curl -fsSL "https://www.ruby-lang.org/$versionReleasePage" |tac|tac| grep "ruby-$tryVersion.tar.xz" -A 5 | awk '/^SHA256:/ { print $2; exit }')" \
					&& [ "$shaVal" ]
			} \
			|| {
				versionReleasePage="$(echo "$newsPage" | grep -oE '<a href="[^"]+">Ruby '"$tryVersion"' Released</a>' | cut -d'"' -f2)" \
					&& [ "$versionReleasePage" ] \
					&& shaVal="$(curl -fsSL "https://www.ruby-lang.org/$versionReleasePage" |tac|tac| grep "ruby-$tryVersion.tar.xz" -A 5 | awk '/^SHA256:/ { print $2; exit }')" \
					&& [ "$shaVal" ]
			} \
		; then
			fullVersion="$tryVersion"
			break
		fi
	done

	if [ -z "$fullVersion" ]; then
		echo >&2 "warning: cannot determine sha for $version (tried all of ${allVersions[*]}); skipping"
		continue
	fi

	echo "$version: $fullVersion; $shaVal"

	for v in \
		alpine{3.7,3.8,3.9} \
		{jessie,stretch}{/slim,} \
	; do
		dir="$version/$v"
		variant="$(basename "$v")"

		[ -d "$dir" ] || continue

		case "$variant" in
			slim|windowsservercore) template="$variant"; tag="$(basename "$(dirname "$dir")")" ;;
			alpine*) template='alpine'; tag="${variant#alpine}" ;;
			*) template='debian'; tag="$variant" ;;
		esac
		template="Dockerfile-${template}.template"

		if [ "$variant" = 'slim' ]; then
			tag+='-slim'
		fi

		sed -r \
			-e 's!%%VERSION%%!'"$version"'!g' \
			-e 's!%%FULL_VERSION%%!'"$fullVersion"'!g' \
			-e 's!%%SHA256%%!'"$shaVal"'!g' \
			-e 's!%%RUBYGEMS%%!'"$rubygems"'!g' \
			-e "$(
				if [ "$version" = 2.3 ] && [[ "$v" = stretch* ]]; then
					echo 's/libssl-dev/libssl1.0-dev/g'
				else
					echo '/libssl1.0-dev/d'
				fi
			)" \
			-e 's/^(FROM (debian|buildpack-deps|alpine)):.*/\1:'"$tag"'/' \
			"$template" > "$dir/Dockerfile"

		case "$variant" in
			alpine3.8 | alpine3.7)
				# Alpine 3.9+ uses OpenSSL, but 3.8/3.7 still uses LibreSSL
				sed -ri -e 's/openssl/libressl/g' "$dir/Dockerfile"
				;;
		esac

		if [ -n "${newEnoughRubygems[$version]:-}" ]; then
			sed -ri -e '/RUBYGEMS_VERSION/d' "$dir/Dockerfile"
		fi

		travisEnv='\n  - VERSION='"$version VARIANT=$v$travisEnv"
	done
done

travis="$(awk -v 'RS=\n\n' '$1 == "env:" { $0 = "env:'"$travisEnv"'" } { printf "%s%s", $0, RS }' .travis.yml)"
echo "$travis" > .travis.yml
