use rustls::internal::msgs::codec::Codec;
use std::error::Error;

/// Keep the FRB schema unchanged: the existing connection-error string carries
/// a tagged hex ECHConfigList. Dart exposes it as RhttpEchRejectedException.
pub(crate) fn rejection_message(error: &(dyn Error + 'static)) -> Option<String> {
    let mut current = Some(error);
    while let Some(source) = current {
        // io::Error::source can skip its wrapped error on some platforms.
        let tls = source.downcast_ref::<rustls::Error>().or_else(|| {
            source
                .downcast_ref::<std::io::Error>()
                .and_then(|io| io.get_ref())
                .and_then(|inner| inner.downcast_ref::<rustls::Error>())
        });
        if let Some(rustls::Error::PeerIncompatible(
            rustls::PeerIncompatible::ServerRejectedEncryptedClientHello(configs),
        )) = tls
        {
            let bytes = configs
                .as_ref()
                .map(Codec::get_encoding)
                .unwrap_or_default();
            let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
            return Some(format!("ECH_REJECTED:{hex}"));
        }
        current = source.source();
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustls::internal::msgs::handshake::EchConfigPayload;

    #[test]
    fn encodes_retry_config_list_through_io_wrapper() {
        // A framed unknown-version config is sufficient to test serialization.
        let bytes = [0, 4, 0xab, 0xcd, 0, 0];
        let configs = Vec::<EchConfigPayload>::read_bytes(&bytes).unwrap();
        let tls = rustls::Error::PeerIncompatible(
            rustls::PeerIncompatible::ServerRejectedEncryptedClientHello(Some(configs)),
        );
        let error = std::io::Error::new(std::io::ErrorKind::Other, tls);
        assert_eq!(
            rejection_message(&error).as_deref(),
            Some("ECH_REJECTED:0004abcd0000")
        );
    }

    #[test]
    fn distinguishes_rejection_without_configs_from_other_errors() {
        let tls = rustls::Error::PeerIncompatible(
            rustls::PeerIncompatible::ServerRejectedEncryptedClientHello(None),
        );
        assert_eq!(rejection_message(&tls).as_deref(), Some("ECH_REJECTED:"));
        let reset = std::io::Error::from(std::io::ErrorKind::ConnectionReset);
        assert_eq!(rejection_message(&reset), None);
    }
}
