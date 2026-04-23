//! Yeat-namespaced backend logic for the v1.3 Yeat Expansion milestone.
//!
//! Phase 20 lands the disk-walker + tag-inference primitives here. Future Yeat
//! phases (21 sibling detect, 23 sidebar filter, 25 era assigner) may add more
//! submodules under this namespace.

pub mod tags;

pub use tags::{detect_variant, infer_tags, normalize_era, walk_yeat_root, TagTriple, WalkedTrack};
