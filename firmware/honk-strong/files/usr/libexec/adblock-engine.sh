#!/bin/sh
# adblock-engine.sh -- fetch custom ad subscriptions, build a v2ray geosite
# overlay, install it into honk's data dir and trigger a live reload.
#
# Runs as root via rpcd. Talks to honk only through two local, root-only
# primitives that need no API password:
#   * write /etc/honk/honk-ads.dat  (overlay path whitelisted in enhanced core)
#   * kill -HUP <honk-core pid>       (core reloads config + overlay from disk)
# The enhanced core mixes overlay bytes into the geosite fingerprint, so every
# SIGHUP with a changed DAT rebuilds the matcher. No config file is touched by
# this script; the one-time `qname(geosite:honk-ads) -> reject` rule is
# installed separately by setup.sh and never modified here.

# OpenWrt /lib/functions.sh and /lib/config/uci.sh are not `set -u` clean.
. /lib/functions.sh

UCI_CONFIG=honk-adblock
GEN=/usr/libexec/honk-adblock/geosite_gen.lua
STAGE_ROOT=/tmp/honk-adblock
DAT_STAGE=$STAGE_ROOT/merged.txt
DAT_OUT=/etc/honk/honk-ads.dat
FETCH_TIMEOUT=${FETCH_TIMEOUT:-25}
MAX_BYTES=${MAX_BYTES:-33554432}   # 32 MiB per subscription download
# Memory note: geosite_gen.lua emits honk type=2 (Domain/suffix) so honk keeps
# ad domains in a HashSet (~0.7 KB/domain). 95k domains use only ~72 MB RSS.
# (The old type=1 wrongly compiled each domain as a Regex at ~15 KB each and
# OOM'd at 1.4 GB — fixed in geosite_gen.lua; do NOT revert to type=1.)
# MAX_DOMAINS is now only a generous safety net against pathological inputs.
MAX_DOMAINS=${MAX_DOMAINS:-500000}

log() { logger -t honk-adblock "$*" 2>/dev/null || :; }

cfg() { uci -q get "$UCI_CONFIG.main.$1" 2>/dev/null; }

# Fetch one URL to stdout. Returns 0 and prints content on success.
fetch_url() {
	local url=$1 tmp rc
	tmp="$STAGE_ROOT/fetch.$$"
	rc=0
	curl -fsSL --max-time "$FETCH_TIMEOUT" \
		--max-filesize "$MAX_BYTES" \
		-A 'Mozilla/5.0 (X11; Linux aarch64) honk-adblock' \
		-o "$tmp" "$url" >/dev/null 2>&1 || rc=$?
	if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
		cat "$tmp"
		rm -f "$tmp"
		return 0
	fi
	rm -f "$tmp"
	return 1
}

# Build the merged domain list from all enabled sources.
# Each source section: option name/url/enabled, option format (auto/hosts/
# domain/adblock/dnsmasq), or option inline (literal rule text base64-free).
build_list() {
	local enabled url content any=0
	mkdir -p "$STAGE_ROOT"
	: > "$DAT_STAGE"
	config_load "$UCI_CONFIG" 2>/dev/null || {
		log "config_load failed"
		return 1
	}
	config_foreach _emit_source source || return 1

	# Hard cap on domain count to keep honk's matcher within device memory.
	# Deduplicate first, then truncate; log when we drop entries.
	local total kept
	total=$(awk 'NF && $1 !~ /^#/' "$DAT_STAGE" 2>/dev/null | wc -l | tr -d ' ')
	if [ -n "$total" ] && [ "$total" -gt "$MAX_DOMAINS" ]; then
		awk 'NF && $1 !~ /^#/ && !seen[$0]++' "$DAT_STAGE" > "$DAT_STAGE.capped"
		mv -f "$DAT_STAGE.capped" "$DAT_STAGE"
		kept=$(wc -l < "$DAT_STAGE" | tr -d ' ')
		# Truncate to the cap after dedup (dedup may still exceed the cap).
		if [ "$kept" -gt "$MAX_DOMAINS" ]; then
			head -n "$MAX_DOMAINS" "$DAT_STAGE" > "$DAT_STAGE.capped2"
			mv -f "$DAT_STAGE.capped2" "$DAT_STAGE"
			kept=$MAX_DOMAINS
		fi
		log "domain cap: $total raw -> $kept kept (MAX_DOMAINS=$MAX_DOMAINS); add fewer/slimmer subscriptions"
	else
		# Still dedup below cap to save memory, preserving order.
		awk 'NF && $1 !~ /^#/ && !seen[$0]++' "$DAT_STAGE" > "$DAT_STAGE.dedup"
		mv -f "$DAT_STAGE.dedup" "$DAT_STAGE"
	fi
	# If nothing produced content, keep an empty list (valid zero-domain category).
	return 0
}

_emit_source() {
	local s=$1 name url fmt enabled inline content tmp lines
	config_get_bool enabled "$s" enabled 0
	[ "$enabled" -eq 1 ] || return 0
	config_get name "$s" name "$s"
	config_get fmt "$s" format auto
	config_get url "$s" url ""
	config_get inline "$s" inline ""

	tmp="$STAGE_ROOT/src.$$.$s"
	if [ -n "$inline" ]; then
		printf '%s\n' "$inline" > "$tmp"
	elif [ -n "$url" ]; then
		case "$url" in
			http://*|https://*)
				if ! fetch_url "$url" > "$tmp"; then
					log "fetch failed for source $name ($url)"
					rm -f "$tmp"
					return 0   # skip bad source, keep the rest
				fi
				;;
			/*)
				[ -r "$url" ] && cat "$url" > "$tmp" || { rm -f "$tmp"; return 0; }
				;;
			*)
				log "unsupported url scheme for $name: $url"
				rm -f "$tmp"
				return 0
				;;
		esac
	else
		return 0
	fi

	# Normalize format-specific lines into one-domain-per-line before lua parse.
	awk -v fmt="$fmt" '
		{
			line=$0
			sub(/\r$/,"",line)
			gsub(/^[[:space:]]+|[[:space:]]+$/,"",line)
			if (line=="" || line ~ /^#/) next
			if (fmt=="adblock" || (fmt=="auto" && line ~ /^\|\|/)) {
				if (match(line, /^\|\|[^^\^]+/)) {
					d=substr(line,3,RLENGTH-2); print d; next
				}
			}
			if (fmt=="dnsmasq" || (fmt=="auto" && line ~ /^(server|address)=\//)) {
				if (match(line, /^\/(.*?)\//)) {
					d=substr(line,RSTART+1,RLENGTH-2); print d; next
				}
			}
			if (fmt=="domain" || fmt=="auto") {
				if (line ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[ \t]+/) {
					sub(/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[ \t]+/,"",line)
					split(line,a,/[[:space:]]+/); print a[1]; next
				}
				if (line ~ /^[A-Za-z0-9._-]+$/) { print line; next }
			}
		}
	' "$tmp" >> "$DAT_STAGE"
	rm -f "$tmp"
	return 0
}

# Regenerate DAT and reload honk. Prints a one-line status; exit 0 on success.
refresh() {
	local category output domcount bytes pid rc=0
	category=$(cfg category); [ -n "$category" ] || category=honk-ads
	output=$(cfg output);     [ -n "$output" ]     || output=$DAT_OUT

	build_list || { echo "build_list_failed"; return 1; }

	# Safety: if every subscription download failed (e.g. transient network),
	# build_list yields an empty stage. Never overwrite a working DAT with an
	# empty one — keep last-known-good so adblock does not silently disappear.
	local staged
	staged=$(awk 'NF && $1 !~ /^#/' "$DAT_STAGE" 2>/dev/null | wc -l | tr -d ' ')
	if [ "${staged:-0}" -eq 0 ] && [ -s "$output" ]; then
		log "all sources empty (network down?) - keeping last-known-good DAT"
		echo "skipped_empty_last_known_good"
		return 1
	fi

	# Always emit a valid (possibly empty) category so enable/disable is clean.
	if ! lua "$GEN" "$DAT_STAGE" "$output.tmp" "$category" >/dev/null 2>&1; then
		rm -f "$output.tmp"
		echo "dat_generate_failed"; return 1
	fi
	mv -f "$output.tmp" "$output" || { echo "dat_install_failed"; return 1; }
	chmod 0644 "$output"

	bytes=$(wc -c < "$output" 2>/dev/null | tr -d ' ')
	domcount=$(awk 'NF && $1 !~ /^#/' "$DAT_STAGE" 2>/dev/null | wc -l | tr -d ' ')

	# Trigger live reload only if honk-core is actually running.
	pid=$(pgrep -f '/usr/bin/honk-core|honk-core ' 2>/dev/null | head -1)
	if [ -n "$pid" ]; then
		if kill -HUP "$pid" 2>/dev/null; then
			log "overlay installed ($domcount domains, ${bytes}B), reloaded pid $pid"
			echo "reloaded:$domcount:$bytes"
		else
			log "overlay installed but SIGHUP failed for pid $pid"
			echo "installed_no_hup:$domcount:$bytes"
			rc=1
		fi
	else
		log "overlay installed ($domcount domains, ${bytes}B); honk not running"
		echo "installed_no_honk:$domcount:$bytes"
	fi
	return $rc
}

# Ensure the one-time DNS reject rule exists in honk's config. honk keeps an
# active config.dae and a config-draft.dae mirror; the lifecycle copies between
# them, so BOTH must carry the rule or it disappears on next start.
ensure_rule() {
	local marker='qname(geosite:honk-ads)' f changed=0
	for f in /etc/honk/config.dae /etc/honk/config-draft.dae; do
		[ -f "$f" ] || continue
		grep -q "$marker" "$f" 2>/dev/null && continue
		# Insert as first rule in dns.routing.request. No trailing comment:
		# dae's legacy parser mis-reads '}' inside a comment line.
		if awk -v marker="$marker" '
			BEGIN{done=0}
			{
				if (!done && $0 ~ /^[[:space:]]*request[[:space:]]*\{/) {
					print $0
					print "            " marker " -> reject"
					done=1; next
				}
				print $0
			}
			END{ if (!done) exit 1 }
		' "$f" > "$f.ha.tmp"; then
			mv -f "$f.ha.tmp" "$f" && changed=1
		else
			rm -f "$f.ha.tmp"
			echo insert_failed; return 1
		fi
	done
	if [ "$changed" -eq 1 ]; then echo installed; else echo present; fi
	return 0
}

case "${1:-}" in
	refresh) refresh ;;
	ensure-rule) ensure_rule ;;
	build-only) build_list; echo "list:$(wc -l < "$DAT_STAGE" 2>/dev/null | tr -d ' ')" ;;
	*) echo "usage: $0 refresh|ensure-rule|build-only" >&2; exit 2 ;;
esac
