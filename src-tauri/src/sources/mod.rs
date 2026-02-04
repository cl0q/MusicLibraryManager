//! Music source integrations module.
//!
//! Provides API clients for streaming services with OAuth authentication,
//! incremental sync, and track provenance tracking.
//!
//! ## Supported Sources
//!
//! - Spotify: Liked songs and playlists via OAuth 2.0 with PKCE
//! - SoundCloud: Liked tracks and playlists via OAuth 2.1 with mandatory PKCE
//!
//! ## Authentication
//!
//! All sources use OAuth 2.0/2.1 Authorization Code flow with PKCE.
//! Refresh tokens are stored securely in the system keychain via
//! the `auth` module.

pub mod soundcloud;
pub mod spotify;

pub use soundcloud::{SoundCloudClient, SoundCloudError};
pub use spotify::{SpotifyClient, SpotifyError};
