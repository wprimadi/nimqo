//! WhatsApp's animated stickers: a zip (".was") holding the Lottie JSON.
//! Read in memory only; the archive comes from the sender, so its size and
//! entry count are capped before anything is unpacked.

use std::io::{Cursor, Read};

/// Larger animations are not shown. Real ones are tens of kilobytes.
const MAX_JSON: u64 = 4 * 1024 * 1024;
const MAX_ENTRIES: usize = 16;

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
    (json.len() as u64 <= MAX_JSON).then_some(json)
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

    #[test]
    fn the_main_animation_is_taken_and_junk_refused() {
        let was = archive(&[
            ("animation/animation_secondary.json", b"{\"b\":2}"),
            ("animation/animation.json", b"{\"a\":1}"),
            ("animation/animation.json.overridden_metadata", b"x"),
        ]);
        assert_eq!(lottie_json(&was).as_deref(), Some(&b"{\"a\":1}"[..]));
        assert_eq!(lottie_json(b"not a zip"), None);
        assert_eq!(lottie_json(&archive(&[("a.png", b"png")])), None);
        let big = vec![b' '; usize::try_from(MAX_JSON).unwrap() + 1];
        assert_eq!(lottie_json(&archive(&[("a.json", &big)])), None);
    }
}
