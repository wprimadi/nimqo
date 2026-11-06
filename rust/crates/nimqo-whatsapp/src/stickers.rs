//! WhatsApp's animated stickers: a zip (".was") holding the Lottie JSON.
//! Read in memory only. Anyone can send one, so the archive and the
//! animation are checked before the app's renderer sees it: a crafted
//! animation could otherwise hang the app (huge canvas, endless frames,
//! thousands of layers, or precompositions that include each other).

use std::collections::HashMap;
use std::io::{Cursor, Read};

use serde_json::Value;

/// Real stickers are tens of kilobytes, 512 px, a few seconds long.
const MAX_JSON: u64 = 1024 * 1024;
const MAX_ENTRIES: usize = 16;
const MAX_SIDE: f64 = 1024.0;
const MAX_FPS: f64 = 120.0;
const MAX_SECONDS: f64 = 10.0;
const MAX_ASSETS: usize = 100;
/// Layers drawn per frame, counting each use of a precomposition.
const MAX_DRAWN_LAYERS: u64 = 500;

/// The main animation's JSON, or `None` if this is not a sticker archive.
#[must_use]
pub fn lottie_json(archive: &[u8]) -> Option<Vec<u8>> {
    let mut zip = zip::ZipArchive::new(Cursor::new(archive)).ok()?;
    if zip.len() > MAX_ENTRIES {
        return None;
    }
    // The main animation; a "secondary" one and metadata may sit beside it.
    let name = zip
        .file_names()
        .filter_map(Result::ok)
        .filter(|n| n.ends_with(".json") && !n.contains("secondary"))
        .min_by_key(|n| n.len())?
        .into_owned();
    let entry = zip.by_name(&name).ok()?;
    if entry.size() > MAX_JSON {
        return None;
    }
    let mut json = Vec::new();
    // The header's size may lie: read at most one byte past the cap.
    entry.take(MAX_JSON + 1).read_to_end(&mut json).ok()?;
    (json.len() as u64 <= MAX_JSON && sane(&json)).then_some(json)
}

/// Whether the animation stays within what a sticker needs.
fn sane(json: &[u8]) -> bool {
    // serde_json caps nesting at 128 levels, so parsing cannot overflow.
    let Ok(root) = serde_json::from_slice::<Value>(json) else {
        return false;
    };
    let num = |key| root.get(key).and_then(Value::as_f64);
    let (Some(w), Some(h), Some(fr), Some(ip), Some(op)) =
        (num("w"), num("h"), num("fr"), num("ip"), num("op"))
    else {
        return false;
    };
    let frames_ok = fr > 0.0 && fr <= MAX_FPS && op > ip && (op - ip) / fr <= MAX_SECONDS;
    let size_ok = w > 0.0 && h > 0.0 && w <= MAX_SIDE && h <= MAX_SIDE;
    if !(frames_ok && size_ok) {
        return false;
    }
    let assets = root
        .get("assets")
        .and_then(Value::as_array)
        .map_or(&[][..], Vec::as_slice);
    if assets.len() > MAX_ASSETS {
        return false;
    }
    let by_id: HashMap<&str, &Value> = assets
        .iter()
        .filter_map(|a| Some((a.get("id")?.as_str()?, a)))
        .collect();
    let mut drawn = HashMap::new();
    layers_drawn(&root, &by_id, &mut drawn, 0).is_some_and(|n| n <= MAX_DRAWN_LAYERS)
}

/// Layers drawn for `node`'s layer list, following precompositions;
/// `None` for a cycle or too many. `drawn` memoizes per asset.
fn layers_drawn<'a>(
    node: &'a Value,
    assets: &HashMap<&'a str, &'a Value>,
    drawn: &mut HashMap<&'a str, Option<u64>>,
    depth: usize,
) -> Option<u64> {
    if depth > MAX_ASSETS {
        return None;
    }
    let mut total: u64 = 0;
    for layer in node
        .get("layers")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        total += 1;
        if let Some(id) = layer.get("refId").and_then(Value::as_str)
            && let Some(asset) = assets.get(id)
        {
            let inner = match drawn.get(id) {
                // Seen on the current path and not finished: a cycle.
                Some(None) => return None,
                Some(Some(n)) => *n,
                None => {
                    drawn.insert(id, None);
                    let n = layers_drawn(asset, assets, drawn, depth + 1)?;
                    drawn.insert(id, Some(n));
                    n
                }
            };
            total = total.saturating_add(inner);
        }
        if total > MAX_DRAWN_LAYERS {
            return None;
        }
    }
    Some(total)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn archive(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        for (name, data) in entries {
            zip.start_file(*name, options).unwrap();
            zip.write_all(data).unwrap();
        }
        zip.finish().unwrap().into_inner()
    }

    const OK: &[u8] = br#"{"w":512,"h":512,"fr":30,"ip":0,"op":90,"layers":[{"ty":4}]}"#;

    fn animation(extra: &str) -> Vec<u8> {
        format!(r#"{{"w":512,"h":512,"fr":30,"ip":0,"op":90,{extra}}}"#).into_bytes()
    }

    #[test]
    fn the_main_animation_is_taken_and_junk_refused() {
        let was = archive(&[
            ("animation/animation_secondary.json", b"{}"),
            ("animation/animation.json", OK),
            ("animation/animation.json.overridden_metadata", b"x"),
        ]);
        assert_eq!(lottie_json(&was).as_deref(), Some(OK));
        assert_eq!(lottie_json(b"not a zip"), None);
        assert_eq!(lottie_json(&archive(&[("a.png", b"png")])), None);
        let big = vec![b' '; usize::try_from(MAX_JSON).unwrap() + 1];
        assert_eq!(lottie_json(&archive(&[("a.json", &big)])), None);
    }

    #[test]
    fn crafted_animations_are_refused() {
        assert!(sane(OK));
        assert!(
            !sane(br#"{"w":100000,"h":512,"fr":30,"ip":0,"op":90}"#),
            "huge canvas"
        );
        assert!(
            !sane(br#"{"w":512,"h":512,"fr":30,"ip":0,"op":1e9}"#),
            "endless"
        );
        assert!(!sane(b"{}"), "not an animation");
        let cycle = r#""assets":[{"id":"a","layers":[{"refId":"b"}]},{"id":"b","layers":[{"refId":"a"}]}],"layers":[{"refId":"a"}]"#;
        assert!(!sane(&animation(cycle)), "precomps that include each other");
        let own = r#""assets":[{"id":"a","layers":[{"refId":"a"}]}],"layers":[{"refId":"a"}]"#;
        assert!(!sane(&animation(own)), "a precomp that includes itself");
        // Each level uses the next ten times: 10^4 layers drawn.
        let fan = |next: &str| {
            format!(
                "[{}]",
                vec![format!(r#"{{"refId":"{next}"}}"#); 10].join(",")
            )
        };
        let deep = format!(
            r#""assets":[{{"id":"a","layers":{}}},{{"id":"b","layers":{}}},{{"id":"c","layers":{}}},{{"id":"d","layers":[{{}}]}}],"layers":{}"#,
            fan("b"),
            fan("c"),
            fan("d"),
            fan("a")
        );
        assert!(!sane(&animation(&deep)), "precomps multiplying layers");
        let shared =
            r#""assets":[{"id":"a","layers":[{},{}]}],"layers":[{"refId":"a"},{"refId":"a"}]"#;
        assert!(sane(&animation(shared)), "a precomp used twice is fine");
    }
}
