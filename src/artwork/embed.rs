//! Artwork embedding into audio files via lofty.
//!
//! This module provides:
//! - Check for existing embedded artwork
//! - Embed artwork into audio file's primary tag
//! - Extract embedded artwork from files
//! - Resize artwork to target dimensions

use anyhow::{anyhow, Result};
use image::GenericImageView;
use lofty::file::AudioFile;
use lofty::picture::{Picture, PictureType};
use lofty::prelude::*;
use lofty::probe::Probe;
use std::io::Cursor;
use std::path::Path;

/// Check if an audio file has embedded front cover artwork.
///
/// # Arguments
/// * `path` - Path to audio file
///
/// # Returns
/// * `Ok(true)` - File has front cover artwork
/// * `Ok(false)` - No front cover artwork
/// * `Err(_)` - Failed to read file
pub fn has_embedded_artwork(path: &Path) -> Result<bool> {
    let tagged_file = Probe::open(path)
        .map_err(|e| anyhow!("Failed to open audio file: {}", e))?
        .read()
        .map_err(|e| anyhow!("Failed to read audio file: {}", e))?;

    if let Some(tag) = tagged_file.primary_tag() {
        // Check if any picture is a front cover
        for picture in tag.pictures() {
            if picture.pic_type() == PictureType::CoverFront {
                return Ok(true);
            }
        }
    }

    Ok(false)
}

/// Embed artwork into an audio file.
///
/// Replaces any existing front cover artwork with the new image.
/// Uses the file's primary tag for maximum compatibility.
///
/// # Arguments
/// * `audio_path` - Path to audio file
/// * `image_data` - JPEG image bytes
///
/// # Returns
/// * `Ok(())` - Artwork embedded successfully
/// * `Err(_)` - Failed to embed artwork
pub fn embed_artwork(audio_path: &Path, image_data: &[u8]) -> Result<()> {
    let mut tagged_file = Probe::open(audio_path)
        .map_err(|e| anyhow!("Failed to open audio file: {}", e))?
        .read()
        .map_err(|e| anyhow!("Failed to read audio file: {}", e))?;

    // Get mutable reference to primary tag
    let tag = tagged_file
        .primary_tag_mut()
        .ok_or_else(|| anyhow!("No primary tag available"))?;

    // Remove existing front cover pictures
    tag.remove_picture_type(PictureType::CoverFront);

    // Create new picture from image data
    let mut cursor = Cursor::new(image_data);
    let picture = Picture::from_reader(&mut cursor)
        .map_err(|e| anyhow!("Failed to create picture from image data: {}", e))?;

    // Set as front cover
    let mut picture = picture;
    picture.set_pic_type(PictureType::CoverFront);

    // Add to tag
    tag.push_picture(picture);

    // Save changes
    use lofty::config::WriteOptions;
    tagged_file
        .save_to_path(audio_path, WriteOptions::default())
        .map_err(|e| anyhow!("Failed to save artwork to file: {}", e))?;

    Ok(())
}

/// Extract embedded artwork from an audio file.
///
/// Returns the first front cover picture found in the file's tags.
///
/// # Arguments
/// * `path` - Path to audio file
///
/// # Returns
/// * `Ok(Some(bytes))` - Artwork data extracted
/// * `Ok(None)` - No artwork found
/// * `Err(_)` - Failed to read file
pub fn extract_embedded_artwork(path: &Path) -> Result<Option<Vec<u8>>> {
    let tagged_file = Probe::open(path)
        .map_err(|e| anyhow!("Failed to open audio file: {}", e))?
        .read()
        .map_err(|e| anyhow!("Failed to read audio file: {}", e))?;

    if let Some(tag) = tagged_file.primary_tag() {
        // Find first front cover picture
        for picture in tag.pictures() {
            if picture.pic_type() == PictureType::CoverFront {
                return Ok(Some(picture.data().to_vec()));
            }
        }
    }

    Ok(None)
}

/// Resize artwork to fit within maximum dimensions.
///
/// Maintains aspect ratio. If image is already smaller than max_dimension,
/// returns original data unchanged.
///
/// # Arguments
/// * `image_data` - Source image bytes
/// * `max_dimension` - Maximum width or height in pixels
///
/// # Returns
/// * `Ok(bytes)` - Resized JPEG bytes (quality 85)
/// * `Err(_)` - Failed to decode or resize image
pub fn resize_artwork(image_data: &[u8], max_dimension: u32) -> Result<Vec<u8>> {
    use image::imageops::FilterType;
    use image::ImageFormat;

    // Decode image
    let img = image::load_from_memory(image_data)
        .map_err(|e| anyhow!("Failed to decode image: {}", e))?;

    let (width, height) = img.dimensions();

    // Check if resize is needed
    if width <= max_dimension && height <= max_dimension {
        // Already small enough, return original
        return Ok(image_data.to_vec());
    }

    // Calculate new dimensions maintaining aspect ratio
    let (new_width, new_height) = if width > height {
        let ratio = max_dimension as f32 / width as f32;
        (max_dimension, (height as f32 * ratio) as u32)
    } else {
        let ratio = max_dimension as f32 / height as f32;
        ((width as f32 * ratio) as u32, max_dimension)
    };

    // Resize using Lanczos3 filter (high quality)
    let resized = img.resize(new_width, new_height, FilterType::Lanczos3);

    // Encode as JPEG with quality 85
    let mut output = Cursor::new(Vec::new());
    resized
        .write_to(&mut output, ImageFormat::Jpeg)
        .map_err(|e| anyhow!("Failed to encode resized image: {}", e))?;

    Ok(output.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_embedded_returns_none() {
        // Create a path that doesn't exist
        let path = Path::new("/nonexistent/file.mp3");
        let result = extract_embedded_artwork(path);

        // Should return error for non-existent file
        assert!(result.is_err());
    }

    #[test]
    fn test_resize_artwork() {
        // Create a small 10x10 red JPEG
        use image::{ImageBuffer, Rgb};
        let img = ImageBuffer::from_fn(10, 10, |_, _| Rgb([255u8, 0u8, 0u8]));

        let mut bytes = Cursor::new(Vec::new());
        img.write_to(&mut bytes, image::ImageFormat::Jpeg).unwrap();
        let jpeg_data = bytes.into_inner();

        // Resize to 500 (should not resize since already smaller)
        let resized = resize_artwork(&jpeg_data, 500).unwrap();

        // Should work without crashing
        assert!(!resized.is_empty());

        // Verify it's still a valid JPEG
        let decoded = image::load_from_memory(&resized).unwrap();
        let (width, height) = decoded.dimensions();

        // Original was 10x10, should stay same since smaller than 500
        assert_eq!(width, 10);
        assert_eq!(height, 10);
    }

    #[test]
    fn test_resize_artwork_downscale() {
        // Create a 1000x500 image
        use image::{ImageBuffer, Rgb};
        let img = ImageBuffer::from_fn(1000, 500, |_, _| Rgb([255u8, 0u8, 0u8]));

        let mut bytes = Cursor::new(Vec::new());
        img.write_to(&mut bytes, image::ImageFormat::Jpeg).unwrap();
        let jpeg_data = bytes.into_inner();

        // Resize to 500
        let resized = resize_artwork(&jpeg_data, 500).unwrap();

        // Verify dimensions
        let decoded = image::load_from_memory(&resized).unwrap();
        let (width, height) = decoded.dimensions();

        // Should maintain aspect ratio: 1000x500 -> 500x250
        assert_eq!(width, 500);
        assert_eq!(height, 250);
    }
}
