extends Node

const BECH32_CHARS = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

static func decode_note1_id(uri: String) -> String:
	var s = uri.strip_edges().to_lower()
	if s.begins_with("nostr:"):
		s = s.substr(6)
	var sep = s.find("1")
	if sep == -1:
		return ""
	var hrp = s.substr(0, sep)
	var data = s.substr(sep + 1)

	var values = []
	for c in data:
		var idx = BECH32_CHARS.find(c)
		if idx == -1:
			return ""
		values.append(idx)

	var len = values.size() - 6
	if len <= 0:
		return ""
	values = values.slice(0, len)

	var bytes = []
	var buffer = 0
	var bits = 0
	for v in values:
		buffer = (buffer << 5) | v
		bits += 5
		if bits >= 8:
			bits -= 8
			bytes.append((buffer >> bits) & 0xFF)
			buffer = buffer & ((1 << bits) - 1)

	if (hrp == "note" or hrp == "nevent") and bytes.size() >= 32:
		var hex = ""
		for i in range(32):
			hex += "%02x" % bytes[i]
		return hex
	return ""

static func resolve_lnurl(profile: Dictionary) -> String:
	if profile.has("lud06"):
		var lud06 = profile["lud06"]
		if lud06.begins_with("lnurl"):
			return lnurl_decode(lud06)
		return lud06

	if profile.has("lud16"):
		var lud16 = profile["lud16"]
		var parts = lud16.split("@")
		if parts.size() == 2:
			return "https://%s/.well-known/lnurlp/%s" % [parts[1], parts[0]]

	return ""

static func lnurl_decode(lnurl: String) -> String:
	var s = lnurl.strip_edges().to_lower()
	var sep = s.find("1")
	if sep == -1:
		return ""
	var data = s.substr(sep + 1)

	var values = []
	for c in data:
		var idx = BECH32_CHARS.find(c)
		if idx == -1:
			return ""
		values.append(idx)

	var bytes = []
	var buffer = 0
	var bits = 0
	for v in values:
		buffer = (buffer << 5) | v
		bits += 5
		if bits >= 8:
			bits -= 8
			bytes.append((buffer >> bits) & 0xFF)
			buffer = buffer & ((1 << bits) - 1)

	var result = ""
	for b in bytes:
		result += char(b)
	return result

static func resolve_custom_emoji(content: String, tags: Array) -> String:
	var trimmed = content.strip_edges()
	if not trimmed.begins_with(":") or not trimmed.ends_with(":"):
		return ""
	var emoji_name = trimmed.trim_prefix(":").trim_suffix(":")
	for tag in tags:
		if tag is Array and tag.size() >= 3 and tag[0] == "emoji" and tag[1] == emoji_name:
			return str(tag[2])
	return ""

static func has_lud(profile: Dictionary) -> bool:
	return profile.has("lud06") or profile.has("lud16")
