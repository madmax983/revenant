//! WebAssembly ABI for the `sf` plugin. No wasm-bindgen: three C exports.
//!
//! 1. The host calls `rl_alloc(n)` and writes `n` bytes of UTF-8 request JSON.
//! 2. The host calls `rl_lint(ptr, n)`. It frees the request and returns the
//!    response as `(ptr << 32) | len`.
//! 3. The host reads the response, then calls `rl_free(ptr, len)`.

#![allow(unsafe_code)] // The ABI needs raw pointers. Each block is small.

use crate::lint_json;

/// Allocates `len` bytes for the host to write. Free with [`rl_free`].
#[unsafe(no_mangle)]
pub extern "C" fn rl_alloc(len: usize) -> *mut u8 {
    Box::into_raw(vec![0u8; len].into_boxed_slice()).cast::<u8>()
}

/// Frees a block from [`rl_alloc`] or [`rl_lint`].
///
/// # Safety
/// `ptr` and `len` must come from one [`rl_alloc`] call or one [`rl_lint`]
/// result, and the host must not use the block again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rl_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: the caller gives a live boxed slice of exactly `len` bytes.
    drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
}

/// Lints the request JSON at `ptr` and frees it. Returns the response JSON
/// as `(ptr << 32) | len`. Free the response with [`rl_free`].
///
/// # Safety
/// `ptr` and `len` must come from one [`rl_alloc`] call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rl_lint(ptr: *mut u8, len: usize) -> u64 {
    // SAFETY: the caller gives a live block from rl_alloc; we take ownership.
    let request = unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) };
    let response = match std::str::from_utf8(&request) {
        Ok(text) => lint_json(text),
        Err(e) => serde_json::json!({ "error": format!("request is not UTF-8: {e}") }).to_string(),
    };
    drop(request);
    let bytes = response.into_bytes().into_boxed_slice();
    let out_len = bytes.len() as u64;
    let out_ptr = Box::into_raw(bytes).cast::<u8>() as usize as u64;
    (out_ptr << 32) | out_len
}
