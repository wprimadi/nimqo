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
/// Items drawn per frame (layers, shapes, groups), each counted once per
/// copy a repeater above it makes and per use of its precomposition.
const MAX_DRAWN: u64 = 5000;
/// Copies one repeater may make, a fixed number.
const MAX_REPEATS: u64 = 20;
/// Precompositions inside precompositions.
const MAX_NESTING: usize = 8;

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
    // Images are refused: a small file can claim a huge size when decoded,
    // and stickers are drawn from shapes. ponytail: allow embedded ones
    // with a checked image header if real stickers turn out to use them.
    if assets.len() > MAX_ASSETS || assets.iter().any(|a| a.get("p").is_some()) {
        return false;
    }
    // Every asset needs its own string id, so no asset escapes the count
    // that the renderer would still find (it may read a number as an id).
    let mut by_id = HashMap::new();
    for asset in assets {
        let Some(id) = asset.get("id").and_then(Value::as_str) else {
            return false;
        };
        if by_id.insert(id, asset).is_some() {
            return false;
        }
    }
    let mut cost = Cost {
        assets: by_id,
        memo: HashMap::new(),
        nesting: 0,
    };
    cost.of(&root).is_some()
}

/// What drawing one frame costs, in items. `None` when over the cap, for
/// precompositions that include each other or nest too deep, and for
/// repeaters with many or animated copies.
struct Cost<'a> {
    assets: HashMap<&'a str, &'a Value>,
    /// Per precomposition: `None` while it is being walked (a cycle if met
    /// again), then its cost.
    memo: HashMap<&'a str, Option<u64>>,
    nesting: usize,
}

impl<'a> Cost<'a> {
    fn of(&mut self, value: &'a Value) -> Option<u64> {
        let total = match value {
            // A list of items; a repeater in it repeats the whole list
            // (over-counts slightly, never under).
            Value::Array(list) => {
                let (mut sum, mut copies) = (0_u64, 1_u64);
                for item in list {
                    sum = sum.saturating_add(self.of(item)?);
                    if item.get("ty").and_then(Value::as_str) == Some("rp") {
                        let n = item.get("c")?.get("k")?.as_u64()?;
                        if n > MAX_REPEATS {
                            return None;
                        }
                        copies = copies.saturating_mul(n.max(1));
                    }
                    if sum > MAX_DRAWN {
                        return None;
                    }
                }
                sum.saturating_mul(copies)
            }
            Value::Object(map) => {
                let mut sum = u64::from(map.contains_key("ty"));
                for (key, inner) in map {
                    // Assets cost where they are used, not where defined.
                    if key != "assets" {
                        sum = sum.saturating_add(self.of(inner)?);
                    }
                    if sum > MAX_DRAWN {
                        return None;
                    }
                }
                // A reference must name a known asset, as a string.
                if let Some(reference) = map.get("refId") {
                    let id = reference.as_str()?;
                    let asset = self.assets.get(id).copied()?;
                    sum = sum.saturating_add(self.precomp(id, asset)?);
                }
                sum
            }
            _ => 0,
        };
        (total <= MAX_DRAWN).then_some(total)
    }

    fn precomp(&mut self, id: &'a str, asset: &'a Value) -> Option<u64> {
        match self.memo.get(id) {
            Some(None) => None,
            Some(Some(n)) => Some(*n),
            None => {
                if self.nesting >= MAX_NESTING {
                    return None;
                }
                self.memo.insert(id, None);
                self.nesting += 1;
                let n = self.of(asset);
                self.nesting -= 1;
                self.memo.insert(id, Some(n?));
                n
            }
        }
    }
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
                vec![format!(r#"{{"ty":0,"refId":"{next}"}}"#); 10].join(",")
            )
        };
        let deep = format!(
            r#""assets":[{{"id":"a","layers":{}}},{{"id":"b","layers":{}}},{{"id":"c","layers":{}}},{{"id":"d","layers":[{{"ty":4}}]}}],"layers":{}"#,
            fan("b"),
            fan("c"),
            fan("d"),
            fan("a")
        );
        assert!(!sane(&animation(&deep)), "precomps multiplying layers");
        let shared =
            r#""assets":[{"id":"a","layers":[{},{}]}],"layers":[{"refId":"a"},{"refId":"a"}]"#;
        assert!(sane(&animation(shared)), "a precomp used twice is fine");
        let image = r#""assets":[{"id":"i","w":10,"h":10,"p":"data:image/png;base64,AA==","e":1}],"layers":[{"refId":"i"}]"#;
        assert!(!sane(&animation(image)), "images");
        let repeat = |copies: &str| {
            animation(&format!(
                r#""layers":[{{"ty":4,"shapes":[{{"ty":"rp","c":{{"a":0,"k":{copies}}}}}]}}]"#
            ))
        };
        assert!(sane(&repeat("3")), "a few copies");
        assert!(!sane(&repeat("100000")), "a repeater making many copies");
        assert!(
            !sane(&repeat(r#"[{"t":0,"s":[1]}]"#)),
            "an animated number of copies"
        );
        let many = vec![r#"{"ty":"el"}"#; usize::try_from(MAX_DRAWN).unwrap() + 1].join(",");
        let shapes = format!(r#""layers":[{{"ty":4,"shapes":[{many}]}}]"#);
        assert!(!sane(&animation(&shapes)), "too many shapes");
        // Groups inside groups, each repeated 20 times: 8000 drawn.
        let nested = r#""layers":[{"ty":4,"shapes":[{"ty":"gr","it":[{"ty":"gr","it":[{"ty":"gr","it":[{"ty":"el"},{"ty":"rp","c":{"a":0,"k":20}}]},{"ty":"rp","c":{"a":0,"k":20}}]},{"ty":"rp","c":{"a":0,"k":20}}]}]}]"#;
        assert!(!sane(&animation(nested)), "repeaters inside repeaters");
        // One precomposition of 1000 shapes used ten times.
        let heavy = vec![r#"{"ty":"el"}"#; 1000].join(",");
        let uses = [r#"{"ty":0,"refId":"p"}"#; 10].join(",");
        let reused = format!(
            r#""assets":[{{"id":"p","layers":[{{"ty":4,"shapes":[{heavy}]}}]}}],"layers":[{uses}]"#
        );
        assert!(
            !sane(&animation(&reused)),
            "a heavy precomp used many times"
        );
        let numeric = r#""assets":[{"id":1,"layers":[]}],"layers":[{"ty":0,"refId":1}]"#;
        assert!(!sane(&animation(numeric)), "a number as an id");
        let twice = r#""assets":[{"id":"a","layers":[]},{"id":"a","layers":[]}],"layers":[]"#;
        assert!(!sane(&animation(twice)), "an id used twice");
        let unknown = r#""layers":[{"ty":0,"refId":"nowhere"}]"#;
        assert!(!sane(&animation(unknown)), "a reference to no asset");
    }
}
