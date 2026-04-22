//! Music source integrations module.
//!
//! Provides API clients for streaming services with OAuth authentication,
//! incremental sync, and track provenance tracking.
//!
//! ## Supported Sources
//!
//! - Spotify: Liked songs and playlists via OAuth 2.0 with PKCE
//! - SoundCloud: Liked tracks and playlists via OAuth 2.1 with mandatory PKCE
//! - Apple Music: Library songs and playlists via scraped dev token + MusicKit JS user auth
//!
//! ## Authentication
//!
//! Spotify and SoundCloud use OAuth 2.0/2.1 Authorization Code flow with PKCE.
//! Apple Music uses a scraped developer token and a user token obtained via
//! MusicKit JS in a Tauri webview (no OAuth2 flow, no refresh tokens).
//! Tokens are stored in the app data directory via the `auth` module.

pub mod apple_music;
pub mod soundcloud;
pub mod spotify;

pub use apple_music::{AppleMusicClient, AppleMusicError, scrape_developer_token};
pub use soundcloud::{SoundCloudClient, SoundCloudError};
pub use spotify::{SpotifyClient, SpotifyError};
