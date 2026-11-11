//! Voice notes: the app's recording, 16 kHz mono PCM, made into the Ogg Opus
//! file WhatsApp plays, with the waveform its bubble draws.

use opus::{Application, Bitrate, Channels, Encoder};

/// The rate the app records at.
pub const RATE: usize = 16_000;
/// 20 ms.
const FRAME: usize = RATE / 50;
/// Ogg Opus counts time at 48 kHz whatever the input rate.
const GRANULE_PER_FRAME: u64 = 960;
/// Bars in WhatsApp's waveform, each 0 to 100.
const BARS: usize = 64;
/// Thirty minutes; WhatsApp's own recorder stops well before.
pub const MAX_SAMPLES: usize = RATE * 60 * 30;
/// A page holds at most 255 lacing values; a second of voice fits easily.
const PACKETS_PER_PAGE: usize = 50;

pub struct VoiceNote {
    pub ogg: Vec<u8>,
    pub seconds: u32,
    pub waveform: Vec<u8>,
}

/// Encodes `pcm`; `None` when it is empty, too long, or Opus fails.
pub fn encode(pcm: &[i16]) -> Option<VoiceNote> {
    if pcm.is_empty() || pcm.len() > MAX_SAMPLES {
        return None;
    }
    #[allow(clippy::cast_possible_truncation, reason = "RATE fits")]
    let mut enc = Encoder::new(RATE as u32, Channels::Mono, Application::Voip).ok()?;
    enc.set_bitrate(Bitrate::Bits(32_000)).ok()?;
    let lookahead = u64::try_from(enc.get_lookahead().ok()?).ok()?;
    let mut packets = Vec::with_capacity(pcm.len() / FRAME + 1);
    for chunk in pcm.chunks(FRAME) {
        let mut frame = [0_i16; FRAME];
        frame[..chunk.len()].copy_from_slice(chunk);
        packets.push(enc.encode_vec(&frame, 1275).ok()?);
    }
    let pre_skip = lookahead * 3;
    let total = pre_skip + pcm.len() as u64 * 3;
    Some(VoiceNote {
        ogg: ogg(&packets, u16::try_from(pre_skip).ok()?, total),
        seconds: u32::try_from(pcm.len().div_ceil(RATE)).ok()?,
        waveform: waveform(pcm),
    })
}

/// The loudest sample of each of 64 stretches, against the loudest overall.
fn waveform(pcm: &[i16]) -> Vec<u8> {
    let step = pcm.len().div_ceil(BARS).max(1);
    let peaks: Vec<u32> = pcm
        .chunks(step)
        .map(|c| {
            c.iter()
                .map(|s| u32::from(s.unsigned_abs()))
                .max()
                .unwrap_or(0)
        })
        .collect();
    let top = peaks.iter().copied().max().unwrap_or(0).max(1);
    let mut bars: Vec<u8> = peaks
        .iter()
        .map(|p| u8::try_from(p * 100 / top).unwrap_or(100))
        .collect();
    bars.resize(BARS, 0);
    bars
}

/// RFC 7845: a head page, a tags page, then the audio, the last page's
/// granule trimmed to the real end.
fn ogg(packets: &[Vec<u8>], pre_skip: u16, total: u64) -> Vec<u8> {
    let serial = 0x4e49_4d51; // "NIMQ"
    let mut head = b"OpusHead".to_vec();
    head.push(1);
    head.push(1);
    head.extend_from_slice(&pre_skip.to_le_bytes());
    #[allow(clippy::cast_possible_truncation, reason = "RATE fits")]
    head.extend_from_slice(&(RATE as u32).to_le_bytes());
    head.extend_from_slice(&[0, 0, 0]);
    let mut tags = b"OpusTags".to_vec();
    tags.extend_from_slice(&5_u32.to_le_bytes());
    tags.extend_from_slice(b"NIMQO");
    tags.extend_from_slice(&0_u32.to_le_bytes());

    let mut out = Vec::new();
    page(&mut out, 0x02, 0, serial, 0, &[&head]);
    page(&mut out, 0, 0, serial, 1, &[&tags]);
    let pages = packets.chunks(PACKETS_PER_PAGE);
    let count = pages.len();
    let mut done = 0_u64;
    for (i, chunk) in pages.enumerate() {
        done += chunk.len() as u64;
        let last = i + 1 == count;
        let granule = if last {
            total
        } else {
            done * GRANULE_PER_FRAME
        };
        let refs: Vec<&[u8]> = chunk.iter().map(Vec::as_slice).collect();
        #[allow(clippy::cast_possible_truncation, reason = "pages stay far below u32")]
        page(
            &mut out,
            if last { 0x04 } else { 0 },
            granule,
            serial,
            i as u32 + 2,
            &refs,
        );
    }
    out
}

fn page(out: &mut Vec<u8>, flags: u8, granule: u64, serial: u32, seq: u32, packets: &[&[u8]]) {
    let mut lacing = Vec::new();
    for p in packets {
        lacing.extend(std::iter::repeat_n(255_u8, p.len() / 255));
        #[allow(clippy::cast_possible_truncation, reason = "a remainder of 255")]
        lacing.push((p.len() % 255) as u8);
    }
    let start = out.len();
    out.extend_from_slice(b"OggS");
    out.push(0);
    out.push(flags);
    out.extend_from_slice(&granule.to_le_bytes());
    out.extend_from_slice(&serial.to_le_bytes());
    out.extend_from_slice(&seq.to_le_bytes());
    out.extend_from_slice(&[0; 4]);
    #[allow(clippy::cast_possible_truncation, reason = "at most 255 lacing values")]
    out.push(lacing.len() as u8);
    out.extend_from_slice(&lacing);
    for p in packets {
        out.extend_from_slice(p);
    }
    let crc = crc(&out[start..]);
    out[start + 22..start + 26].copy_from_slice(&crc.to_le_bytes());
}

/// Ogg's CRC-32: polynomial 0x04c11db7, unreflected, no final xor.
fn crc(data: &[u8]) -> u32 {
    let mut crc = 0_u32;
    for &byte in data {
        crc ^= u32::from(byte) << 24;
        for _ in 0..8 {
            crc = if crc & 0x8000_0000 == 0 {
                crc << 1
            } else {
                (crc << 1) ^ 0x04c1_1db7
            };
        }
    }
    crc
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_recording_becomes_valid_ogg_opus() {
        // 1.5 s of a 440 Hz tone that gets louder.
        #[allow(clippy::cast_possible_truncation, clippy::cast_precision_loss)]
        let pcm: Vec<i16> = (0..24_000)
            .map(|i| {
                let t = i as f32 / RATE as f32;
                ((t * 440.0 * std::f32::consts::TAU).sin() * 8000.0 * t) as i16
            })
            .collect();
        let note = encode(&pcm).expect("encodes");
        // To listen to, or check with `afinfo`.
        if let Some(path) = std::env::var_os("NIMQO_VOICE_OUT") {
            std::fs::write(path, &note.ogg).unwrap();
        }
        assert_eq!(note.seconds, 2);
        assert_eq!(note.waveform.len(), BARS);
        assert!(note.waveform[0] < note.waveform[60], "gets louder");
        assert_eq!(note.waveform.iter().max(), Some(&100));

        // Walk the pages: each checks out, the first and last are flagged.
        let mut at = 0;
        let mut pages = Vec::new();
        while at < note.ogg.len() {
            let p = &note.ogg[at..];
            assert_eq!(&p[..4], b"OggS");
            let n = usize::from(p[26]);
            let body: usize = p[27..27 + n].iter().map(|&l| usize::from(l)).sum();
            let len = 27 + n + body;
            let mut copy = p[..len].to_vec();
            copy[22..26].fill(0);
            assert_eq!(crc(&copy).to_le_bytes(), p[22..26], "page crc");
            pages.push((p[5], u64::from_le_bytes(p[6..14].try_into().unwrap())));
            at += len;
        }
        assert_eq!(&note.ogg[28..36], b"OpusHead");
        assert_eq!(pages.first().map(|p| p.0), Some(0x02));
        let (flags, granule) = *pages.last().unwrap();
        assert_eq!(flags, 0x04);
        assert!(
            granule > 24_000 * 3,
            "the end, at 48 kHz, after the pre-skip"
        );
        assert!(encode(&[]).is_none());
    }
}
