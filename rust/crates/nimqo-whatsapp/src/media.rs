//! Encrypted media files (ADR 0006).
//!
//! Format: `"NQM1" || salt[32] || segments`. The file key is
//! HKDF-SHA256(media root key, salt, "nimqo/v1/media-file"), unique per file.
//! Segments are 64 KiB of plaintext sealed with ChaCha20-Poly1305 in the
//! STREAM construction (Hoang et al. 2015; RustCrypto `aead-stream`
//! `StreamBE32`), the same construction age and Tink use. The header is the
//! associated data of every segment. Truncation, reordering, and tampering
//! fail authentication.

use aead_stream::aead::Payload;
use aead_stream::{DecryptorBE32, EncryptorBE32, Nonce, StreamBE32};
use anyhow::{Result, anyhow, ensure};
use chacha20poly1305::{ChaCha20Poly1305, KeyInit};
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::vault::fill_random;

const MAGIC: &[u8; 4] = b"NQM1";
const HEADER: usize = MAGIC.len() + 32;
const SEGMENT: usize = 64 * 1024;
const TAG: usize = 16;

/// Encrypts `plain` with a fresh per-file key derived from `root`.
///
/// # Errors
/// The random generator fails or the file exceeds the STREAM counter range.
pub fn encrypt(root: &[u8; 32], plain: &[u8]) -> Result<Vec<u8>> {
    let mut header = [0u8; HEADER];
    header[..MAGIC.len()].copy_from_slice(MAGIC);
    fill_random(&mut header[MAGIC.len()..])?;

    let mut enc = EncryptorBE32::from_aead(file_cipher(root, &header), &zero_nonce());
    let (init, last) = plain.split_at(last_segment_start(plain.len(), SEGMENT));
    let mut out = Vec::with_capacity(HEADER + plain.len() + (plain.len() / SEGMENT + 1) * TAG);
    out.extend_from_slice(&header);
    for seg in init.chunks(SEGMENT) {
        out.extend(
            enc.encrypt_next(Payload {
                msg: seg,
                aad: &header,
            })
            .map_err(|_| sealing_failed())?,
        );
    }
    // Always sealed, even when empty, so truncation is detected.
    out.extend(
        enc.encrypt_last(Payload {
            msg: last,
            aad: &header,
        })
        .map_err(|_| sealing_failed())?,
    );
    Ok(out)
}

/// Decrypts a file produced by [`encrypt`].
///
/// # Errors
/// The data is not a NIMQO media file, or authentication fails.
pub fn decrypt(root: &[u8; 32], data: &[u8]) -> Result<Zeroizing<Vec<u8>>> {
    ensure!(
        data.len() >= HEADER + TAG && data.starts_with(MAGIC),
        "not a NIMQO media file"
    );
    let (header, body) = data.split_at(HEADER);
    let mut dec = DecryptorBE32::from_aead(file_cipher(root, header), &zero_nonce());
    let (init, last) = body.split_at(last_segment_start(body.len(), SEGMENT + TAG));
    let mut out = Zeroizing::new(Vec::with_capacity(body.len()));
    for seg in init.chunks(SEGMENT + TAG) {
        let plain = Zeroizing::new(
            dec.decrypt_next(Payload {
                msg: seg,
                aad: header,
            })
            .map_err(|_| auth_failed())?,
        );
        out.extend_from_slice(&plain);
    }
    let plain = Zeroizing::new(
        dec.decrypt_last(Payload {
            msg: last,
            aad: header,
        })
        .map_err(|_| auth_failed())?,
    );
    out.extend_from_slice(&plain);
    Ok(out)
}

/// Offset of the final segment: the last full or partial `size` block.
fn last_segment_start(len: usize, size: usize) -> usize {
    len.saturating_sub(1) / size * size
}

fn sealing_failed() -> anyhow::Error {
    anyhow!("media encryption failed")
}

fn auth_failed() -> anyhow::Error {
    anyhow!("media file failed authentication")
}

/// The per-file key is unique, so a zero STREAM nonce prefix is safe.
fn zero_nonce() -> Nonce<ChaCha20Poly1305, StreamBE32<ChaCha20Poly1305>> {
    Nonce::<ChaCha20Poly1305, StreamBE32<ChaCha20Poly1305>>::default()
}

fn file_cipher(root: &[u8; 32], header: &[u8]) -> ChaCha20Poly1305 {
    let mut key = Zeroizing::new([0u8; 32]);
    Hkdf::<Sha256>::new(Some(&header[MAGIC.len()..]), root)
        .expand(b"nimqo/v1/media-file", key.as_mut_slice())
        .expect("32 bytes is a valid HKDF-SHA256 output length");
    ChaCha20Poly1305::new(&(*key).into())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROOT: [u8; 32] = [9; 32];

    #[test]
    fn round_trips_at_segment_boundaries() {
        for len in [0, 1, SEGMENT - 1, SEGMENT, SEGMENT + 1, 3 * SEGMENT] {
            let plain: Vec<u8> = (0..len).map(|i| u8::try_from(i % 251).unwrap()).collect();
            let sealed = encrypt(&ROOT, &plain).unwrap();
            assert_eq!(*decrypt(&ROOT, &sealed).unwrap(), plain, "len {len}");
        }
    }

    #[test]
    fn rejects_tampering_truncation_and_wrong_key() {
        let plain = vec![7u8; 2 * SEGMENT + 10];
        let sealed = encrypt(&ROOT, &plain).unwrap();
        assert!(
            !sealed.windows(64).any(|w| w == &plain[..64]),
            "plaintext visible"
        );

        let mut flipped = sealed.clone();
        flipped[HEADER + 5] ^= 1;
        assert!(decrypt(&ROOT, &flipped).is_err());

        let mut salt = sealed.clone();
        salt[6] ^= 1;
        assert!(decrypt(&ROOT, &salt).is_err());

        // Dropping the final segment must not yield a valid shorter file.
        assert!(decrypt(&ROOT, &sealed[..HEADER + 2 * (SEGMENT + TAG)]).is_err());
        assert!(decrypt(&[1; 32], &sealed).is_err());
        assert!(decrypt(&ROOT, b"NQM1").is_err());
    }

    #[test]
    fn each_file_gets_a_fresh_key() {
        assert_ne!(
            encrypt(&ROOT, b"same").unwrap(),
            encrypt(&ROOT, b"same").unwrap()
        );
    }
}
