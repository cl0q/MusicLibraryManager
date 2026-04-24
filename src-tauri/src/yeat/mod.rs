//! Yeat-namespaced backend logic for the v1.3 Yeat Expansion milestone.
//!
//! Phase 20 lands the disk-walker + tag-inference primitives here. Phase 21
//! Plan 02 adds sibling detection. Future Yeat phases (23 sidebar filter,
//! 25 era assigner) may add more submodules under this namespace.

pub mod siblings;
pub mod tags;

pub use siblings::{
    detect_album_siblings, write_sibling_report, AmbiguousSiblings, MultiBaseCandidate,
    OrphanVariant, SiblingReport,
};
pub use tags::{detect_variant, infer_tags, normalize_era, walk_yeat_root, TagTriple, WalkedTrack};
