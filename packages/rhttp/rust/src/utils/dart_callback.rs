use flutter_rust_bridge::DartFnFuture;

/// Awaits a call into Dart without tying the reply to the caller's future.
///
/// flutter_rust_bridge (2.11.1) delivers a Dart callback's result through a
/// oneshot channel and `unwrap`s the send. When the awaiting future is dropped
/// first (a cancelled request leaving `tokio::select!`, reqwest abandoning a
/// DNS lookup), the receiver is gone and the late reply panics, which aborts
/// the app (`panic = "abort"`). Running the call as its own task keeps the
/// receiver alive until Dart answers, whatever happens to the caller.
pub(crate) async fn call_dart<T: Send + 'static>(call: DartFnFuture<T>) -> T {
    match tokio::spawn(call).await {
        Ok(value) => value,
        Err(e) => std::panic::resume_unwind(e.into_panic()),
    }
}
