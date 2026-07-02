//! Generated from the vendored CLDR aliases.json `languageAlias` table —
//! the multi-subtag keys that are structurally valid unicode_language_ids
//! (sgn-BR, cel-gaulish, und-hepburn-heploc, ...). Specific-language keys
//! sort before the `und` wildcards, longer variant sets first; the runtime
//! takes the first match. Regenerate when vendor/cldr/json is refreshed
//! (see tools/fetch-cldr.sh).

pub const MultiSubtagAlias = struct {
    lang: []const u8, // "und" = any language
    script: []const u8,
    region: []const u8,
    variants: []const []const u8,
    r_lang: []const u8, // "und" = keep the input language
    r_script: []const u8,
    r_region: []const u8,
    r_variants: []const []const u8,
};

pub const multi_subtag_aliases = [_]MultiSubtagAlias{
    .{ .lang = "aa", .script = "", .region = "", .variants = &.{"saaho"}, .r_lang = "ssy", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "art", .script = "", .region = "", .variants = &.{"lojban"}, .r_lang = "jbo", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "cel", .script = "", .region = "", .variants = &.{"gaulish"}, .r_lang = "xtg", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "hy", .script = "", .region = "", .variants = &.{"arevmda"}, .r_lang = "hyw", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "no", .script = "", .region = "", .variants = &.{"bokmal"}, .r_lang = "nb", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "no", .script = "", .region = "", .variants = &.{"nynorsk"}, .r_lang = "nn", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "zh", .script = "", .region = "", .variants = &.{"guoyu"}, .r_lang = "zh", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "zh", .script = "", .region = "", .variants = &.{"hakka"}, .r_lang = "hak", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "zh", .script = "", .region = "", .variants = &.{"xiang"}, .r_lang = "hsn", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "BR", .variants = &.{}, .r_lang = "bzs", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "CO", .variants = &.{}, .r_lang = "csn", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "DE", .variants = &.{}, .r_lang = "gsg", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "DK", .variants = &.{}, .r_lang = "dsl", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "ES", .variants = &.{}, .r_lang = "ssp", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "FR", .variants = &.{}, .r_lang = "fsl", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "GB", .variants = &.{}, .r_lang = "bfi", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "GR", .variants = &.{}, .r_lang = "gss", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "IE", .variants = &.{}, .r_lang = "isg", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "IT", .variants = &.{}, .r_lang = "ise", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "JP", .variants = &.{}, .r_lang = "jsl", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "MX", .variants = &.{}, .r_lang = "mfs", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "NI", .variants = &.{}, .r_lang = "ncs", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "NL", .variants = &.{}, .r_lang = "dse", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "NO", .variants = &.{}, .r_lang = "nsi", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "PT", .variants = &.{}, .r_lang = "psr", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "SE", .variants = &.{}, .r_lang = "swl", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "US", .variants = &.{}, .r_lang = "ase", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "sgn", .script = "", .region = "ZA", .variants = &.{}, .r_lang = "sfs", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "und", .script = "", .region = "", .variants = &.{ "hepburn", "heploc" }, .r_lang = "und", .r_script = "", .r_region = "", .r_variants = &.{"alalc97"} },
    .{ .lang = "und", .script = "", .region = "", .variants = &.{"aaland"}, .r_lang = "und", .r_script = "", .r_region = "AX", .r_variants = &.{} },
    .{ .lang = "und", .script = "", .region = "", .variants = &.{"arevela"}, .r_lang = "und", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "und", .script = "", .region = "", .variants = &.{"arevmda"}, .r_lang = "und", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "und", .script = "", .region = "", .variants = &.{"bokmal"}, .r_lang = "und", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "und", .script = "", .region = "", .variants = &.{"hakka"}, .r_lang = "und", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "und", .script = "", .region = "", .variants = &.{"lojban"}, .r_lang = "und", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "und", .script = "", .region = "", .variants = &.{"nynorsk"}, .r_lang = "und", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "und", .script = "", .region = "", .variants = &.{"saaho"}, .r_lang = "und", .r_script = "", .r_region = "", .r_variants = &.{} },
    .{ .lang = "und", .script = "", .region = "", .variants = &.{"xiang"}, .r_lang = "und", .r_script = "", .r_region = "", .r_variants = &.{} },
};
