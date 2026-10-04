//! Observe's Linux module (`modules/observe/linux/launch.rs`, Exact Observe
//! design §4.5–4.6) against a local sink: its wire, its event rules, its
//! dispatch rules and its panic record. Its own binary: it installs a panic
//! hook and points `XDG_STATE_HOME` at a scratch directory.

mod observe {
    include!("../../../../modules/observe/linux/launch.rs");

    #[cfg(test)]
    mod tests;
}
