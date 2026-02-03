use anyhow::{Context, Result};
use std::fs::File;
use std::path::Path;
use symphonia::core::codecs::{CodecType, CODEC_TYPE_ALAC, CODEC_TYPE_FLAC, CODEC_TYPE_WAVPACK};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

#[cfg(test)]
use symphonia::core::codecs::{CODEC_TYPE_AAC, CODEC_TYPE_MP3, CODEC_TYPE_OPUS, CODEC_TYPE_VORBIS};

/// Represents detected audio format with codec and quality information
#[derive(Debug, Clone, PartialEq)]
pub struct AudioFormat {
    /// Audio codec type (FLAC, AAC, MP3, etc.)
    pub codec: CodecType,
    /// Bitrate in bits per second (None if variable/unknown)
    pub bitrate: Option<u64>,
    /// Sample rate in Hz
    pub sample_rate: Option<u32>,
    /// Whether codec is lossless
    pub is_lossless: bool,
}

impl AudioFormat {
    /// Create AudioFormat with codec-based lossless detection
    fn new(codec: CodecType, bitrate: Option<u64>, sample_rate: Option<u32>) -> Self {
        let is_lossless = Self::codec_is_lossless(codec);
        Self {
            codec,
            bitrate,
            sample_rate,
            is_lossless,
        }
    }

    /// Determine if a codec is lossless based on codec type
    fn codec_is_lossless(codec: CodecType) -> bool {
        // Check against well-known lossless codec types
        codec == CODEC_TYPE_FLAC || codec == CODEC_TYPE_ALAC || codec == CODEC_TYPE_WAVPACK
        // Note: PCM formats also lossless, but WAV files typically probed as PCM_* variants
        // For device sync purposes, we primarily care about FLAC/ALAC detection
    }
}

/// Detect audio format from file using Symphonia
///
/// Reads codec metadata from file headers (not file extension)
/// to accurately determine format and quality characteristics.
pub fn detect_format(file_path: &Path) -> Result<AudioFormat> {
    // Open file
    let file = File::open(file_path)
        .with_context(|| format!("Failed to open file: {}", file_path.display()))?;

    // Create media source stream
    let mss = MediaSourceStream::new(Box::new(file), Default::default());

    // Provide format hint from file extension
    let mut hint = Hint::new();
    if let Some(ext) = file_path.extension() {
        hint.with_extension(ext.to_str().unwrap_or(""));
    }

    // Probe the media source for format
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &Default::default(), &MetadataOptions::default())
        .with_context(|| format!("Failed to probe audio format: {}", file_path.display()))?;

    // Get default track (first audio track)
    let track = probed
        .format
        .default_track()
        .with_context(|| format!("No audio track found in: {}", file_path.display()))?;

    // Extract codec parameters
    let codec_params = &track.codec_params;
    let codec = codec_params.codec;
    let sample_rate = codec_params.sample_rate;

    // Calculate bitrate from bits_per_coded_sample * sample_rate * channels (if available)
    let bitrate = if let (Some(bits), Some(rate), Some(channels)) = (
        codec_params.bits_per_coded_sample,
        codec_params.sample_rate,
        codec_params.channels,
    ) {
        Some((bits as u64) * (rate as u64) * (channels.count() as u64))
    } else {
        None
    };

    Ok(AudioFormat::new(codec, bitrate, sample_rate))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_codec_lossless_detection() {
        // Lossless formats
        assert!(AudioFormat::codec_is_lossless(CODEC_TYPE_FLAC));
        assert!(AudioFormat::codec_is_lossless(CODEC_TYPE_ALAC));
        assert!(AudioFormat::codec_is_lossless(CODEC_TYPE_WAVPACK));

        // Lossy formats
        assert!(!AudioFormat::codec_is_lossless(CODEC_TYPE_MP3));
        assert!(!AudioFormat::codec_is_lossless(CODEC_TYPE_AAC));
        assert!(!AudioFormat::codec_is_lossless(CODEC_TYPE_OPUS));
        assert!(!AudioFormat::codec_is_lossless(CODEC_TYPE_VORBIS));
    }

    #[test]
    fn test_audio_format_new() {
        let format = AudioFormat::new(CODEC_TYPE_FLAC, Some(1411200), Some(44100));
        assert_eq!(format.codec, CODEC_TYPE_FLAC);
        assert_eq!(format.bitrate, Some(1411200));
        assert_eq!(format.sample_rate, Some(44100));
        assert!(format.is_lossless);

        let mp3_format = AudioFormat::new(CODEC_TYPE_MP3, Some(320000), Some(44100));
        assert_eq!(mp3_format.codec, CODEC_TYPE_MP3);
        assert!(!mp3_format.is_lossless);
    }
}
