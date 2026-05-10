//! Audio decoding to raw PCM samples.
//!
//! Provides a unified decode pipeline using Symphonia that outputs interleaved i16 PCM samples.
//! This is shared infrastructure used by both fingerprinting and ReplayGain modules.

use std::fs::File;
use std::path::Path;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum DecodeError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Symphonia error: {0}")]
    Symphonia(String),

    #[error("No supported audio tracks found")]
    NoAudioTrack,

    #[error("No codec parameters found")]
    NoCodecParams,
}

impl From<SymphoniaError> for DecodeError {
    fn from(err: SymphoniaError) -> Self {
        DecodeError::Symphonia(err.to_string())
    }
}

/// Decode an audio file to raw interleaved i16 PCM samples.
///
/// # Arguments
/// * `path` - Path to the audio file
///
/// # Returns
/// * `Ok((samples, sample_rate, channels))` - Interleaved PCM samples, sample rate in Hz, and channel count
/// * `Err(DecodeError)` - If decoding fails
///
/// # Example
/// ```no_run
/// use music_library_manager::audio::decode_to_pcm;
/// use std::path::Path;
///
/// let (samples, sample_rate, channels) = decode_to_pcm(Path::new("track.mp3")).unwrap();
/// println!("Decoded {} samples at {}Hz with {} channels", samples.len(), sample_rate, channels);
/// ```
pub fn decode_to_pcm(path: &Path) -> Result<(Vec<i16>, u32, u16), DecodeError> {
    // Open the file
    let file = File::open(path)?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    // Create a hint based on file extension
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|s| s.to_str()) {
        hint.with_extension(ext);
    }

    // Probe the file to detect format
    let probe = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())?;

    let mut format = probe.format;

    // Get the default track (first audio track)
    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or(DecodeError::NoAudioTrack)?;

    let track_id = track.id;

    // Clone codec params to avoid borrowing issues
    let codec_params = track.codec_params.clone();

    // Extract sample rate and channels with defaults
    let sample_rate = codec_params.sample_rate.unwrap_or(44100);
    let channels = codec_params.channels.map(|c| c.count()).unwrap_or(2) as u16;

    // Create decoder
    let mut decoder = symphonia::default::get_codecs()
        .make(&codec_params, &DecoderOptions::default())?;

    // Collect all samples
    let mut all_samples = Vec::new();
    let mut sample_buf: Option<SampleBuffer<i16>> = None;

    loop {
        // Read next packet
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(SymphoniaError::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => {
                break;
            }
            Err(SymphoniaError::ResetRequired) => {
                // Decoder needs reset, recreate it
                decoder = symphonia::default::get_codecs()
                    .make(&codec_params, &DecoderOptions::default())?;
                continue;
            }
            Err(e) => return Err(e.into()),
        };

        // Skip packets for other tracks
        if packet.track_id() != track_id {
            continue;
        }

        // Decode the packet
        let decoded = match decoder.decode(&packet) {
            Ok(decoded) => decoded,
            Err(SymphoniaError::DecodeError(_)) => {
                // Skip corrupted packets
                continue;
            }
            Err(e) => return Err(e.into()),
        };

        // Initialize sample buffer on first decode
        if sample_buf.is_none() {
            let spec = *decoded.spec();
            let duration = decoded.capacity() as u64;
            sample_buf = Some(SampleBuffer::<i16>::new(duration, spec));
        }

        // Copy decoded samples to our buffer (interleaved)
        if let Some(ref mut buf) = sample_buf {
            buf.copy_interleaved_ref(decoded);
            all_samples.extend_from_slice(buf.samples());
        }
    }

    Ok((all_samples, sample_rate, channels))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_decode_to_pcm_signature() {
        // This test verifies the function signature compiles correctly
        // A full decode test requires an actual audio file
        let result: Result<(Vec<i16>, u32, u16), DecodeError> =
            decode_to_pcm(Path::new("nonexistent.mp3"));

        // Should fail with IO error (file not found)
        assert!(result.is_err());
        match result {
            Err(DecodeError::Io(_)) => {
                // Expected
            }
            _ => panic!("Expected IO error for missing file"),
        }
    }

    #[test]
    fn test_decode_error_display() {
        let err = DecodeError::NoAudioTrack;
        assert_eq!(err.to_string(), "No supported audio tracks found");
    }
}
