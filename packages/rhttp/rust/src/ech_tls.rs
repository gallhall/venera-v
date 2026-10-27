use crate::api::client::TlsSettings;
use rustls::client::{danger::*, EchConfig, EchMode};
use rustls::pki_types::{
    pem::PemObject, CertificateDer, EchConfigListBytes, PrivateKeyDer, ServerName, UnixTime,
};
use rustls::{ClientConfig, DigitallySignedStruct, Error, RootCertStore, SignatureScheme};
use std::sync::Arc;

pub(crate) fn build(settings: &TlsSettings, list: Vec<u8>) -> Result<ClientConfig, Error> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let ech = EchConfig::new(
        EchConfigListBytes::from(list),
        crate::ech_hpke::ALL_SUPPORTED_SUITES,
    )?;
    // with_ech selects TLS 1.3 exclusively.
    let builder =
        ClientConfig::builder_with_provider(provider.clone()).with_ech(EchMode::Enable(ech))?;
    let mut roots = RootCertStore::empty();
    if settings.trust_root_certificates {
        roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    }
    for pem in &settings.trusted_root_certificates {
        let certs = CertificateDer::pem_slice_iter(pem)
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| Error::General(format!("Invalid trusted PEM: {e}")))?;
        if certs.is_empty() {
            return Err(Error::General("Empty trusted PEM".into()));
        }
        for cert in certs {
            roots.add(cert)?;
        }
    }
    let builder = if settings.verify_certificates {
        builder.with_root_certificates(roots)
    } else {
        builder
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoVerifier))
    };
    let mut config = if let Some(identity) = &settings.client_certificate {
        let certs = CertificateDer::pem_slice_iter(&identity.certificate)
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| Error::General(format!("Invalid client certificate: {e}")))?;
        let key = PrivateKeyDer::from_pem_slice(&identity.private_key)
            .map_err(|e| Error::General(format!("Invalid client key: {e}")))?;
        builder.with_client_auth_cert(certs, key)?
    } else {
        builder.with_no_client_auth()
    };
    config.enable_sni = true;
    config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    Ok(config)
}

// Matches reqwest's danger_accept_invalid_certs path; used only when explicitly requested.
#[derive(Debug)]
struct NoVerifier;
impl ServerCertVerifier for NoVerifier {
    fn verify_server_cert(
        &self,
        _: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        Ok(HandshakeSignatureValid::assertion())
    }
    fn verify_tls13_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        Ok(HandshakeSignatureValid::assertion())
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    // Offline fixture: draft-18 ECH, X25519 RFC 7748 public key, Cloudflare-style
    // public_name and AES-128-GCM / ChaCha20 suites. Not a live server config.
    const CLOUDFLARE_STYLE: &[u8] = &[
        0x00, 0x49, 0xfe, 0x0d, 0x00, 0x45, 0x01, 0x00, 0x20, 0x00, 0x20, 0x85, 0x20, 0xf0, 0x09,
        0x89, 0x30, 0xa7, 0x54, 0x74, 0x8b, 0x7d, 0xdc, 0xb4, 0x3e, 0xf7, 0x5a, 0x0d, 0xbf, 0x3a,
        0x0d, 0x26, 0x38, 0x1a, 0xf4, 0xeb, 0xa4, 0xa9, 0x8e, 0xaa, 0x9b, 0x4e, 0x6a, 0x00, 0x08,
        0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x03, 0x00, 0x12, b'c', b'l', b'o', b'u', b'd',
        b'f', b'l', b'a', b'r', b'e', b'-', b'e', b'c', b'h', b'.', b'c', b'o', b'm', 0x00, 0x00,
    ];
    #[test]
    fn cloudflare_style_config() {
        EchConfig::new(
            EchConfigListBytes::from(CLOUDFLARE_STYLE),
            crate::ech_hpke::ALL_SUPPORTED_SUITES,
        )
        .unwrap();
        assert!(EchConfig::new(
            EchConfigListBytes::from(vec![0, 0]),
            crate::ech_hpke::ALL_SUPPORTED_SUITES
        )
        .is_err());
    }
}
