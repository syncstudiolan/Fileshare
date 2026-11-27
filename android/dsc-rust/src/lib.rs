//! JNI adapter to the exact upstream PDF Craft signature engine.
//! The Kotlin caller retains separate strict trust/revocation policy.
use jni::{JNIEnv, objects::{JByteArray, JClass, JObjectArray, JString}, sys::jstring};
use pdfcraft_sign::{Certificate, Modification, Status, TrustStore};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::sync::{Arc, Once};

static INIT: Once = Once::new();
const MAX: usize = 64 * 1024 * 1024;

fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|v| format!("{v:02x}")).collect::<Vec<_>>().join("")
}
fn inspect(bytes: Vec<u8>, password: String, roots: Vec<Vec<u8>>) -> Result<Value,String> {
    if bytes.is_empty() || bytes.len() > MAX || roots.len() > 256 {
        return Err("Input exceeds DSC safety limit".into());
    }
    INIT.call_once(pdfcraft_sign::init_crypto);
    let mut certs = Vec::new();
    for raw in roots {
        if raw.len() > 128 * 1024 { return Err("Certificate exceeds limit".into()); }
        certs.push(Certificate::parse(&raw).map_err(|e| e.to_string())?);
    }
    let bytes = Arc::new(bytes);
    let doc = pdfcraft_cos::Document::open_with_password(bytes.clone(),
        if password.is_empty() { None } else { Some(password.as_str()) })
        .map_err(|e| e.to_string())?;
    let signatures = pdfcraft_sign::signatures(&doc, bytes.as_slice(), &TrustStore { certs });
    if signatures.len() > 64 { return Err("Too many signatures".into()); }
    let result: Vec<Value> = signatures.into_iter().filter(|s| s.signed).map(|s| {
        let (modification, changes) = match &s.modification {
            Modification::None => ("none", Vec::new()),
            Modification::Allowed(items) => ("allowed",items.clone()),
            Modification::Disallowed(items) => ("disallowed",items.clone()),
        };
        json!({
            "field": s.field, "signed_len": s.signed_len,
            "fingerprint": s.certificate.as_ref().map(|c| digest(&c.raw)),
            "certificate_hex": s.certificate.as_ref().filter(|c| c.raw.len() <= 128 * 1024).map(|c| c.raw.iter().map(|b| format!("{b:02x}")).collect::<String>()),
            "digest": s.digest.map(|d| d.name()),
            // In upstream approval validation, chain is populated only after
            // successful cryptographic signature verification in finish_validation.
            "integrity_checked": !s.doc_timestamp && s.certificate.as_ref().is_some_and(|c| s.chain.first().is_some_and(|first| first.raw == c.raw)),
            "status": match s.status { Status::Valid => "valid", Status::Unknown => "unknown", Status::Invalid => "invalid" },
            "modification": modification, "changes": changes,
            "details": s.details.iter().take(32).map(|d| &d.message).collect::<Vec<_>>(),
        })
    }).collect();
    Ok(json!({"signatures":result}))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_sammyi57_pdftools_DscRustBridge_verifyNative(
    mut env: JNIEnv, _class: JClass, bytes: JByteArray, password: JString, roots: JObjectArray,
) -> jstring {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<Value,String> {
        let length = env.get_array_length(&bytes).map_err(|e|e.to_string())?;
        if length <= 0 || length as usize > MAX { return Err("PDF size limit".into()); }
        let bytes = env.convert_byte_array(&bytes).map_err(|e|e.to_string())?;
        let password: String = env.get_string(&password).map_err(|e|e.to_string())?.into();
        let count = env.get_array_length(&roots).map_err(|e|e.to_string())?;
        if !(0..=256).contains(&count) { return Err("Trust count limit".into()); }
        let mut certificates = Vec::new();
        for i in 0..count {
            let item = env.get_object_array_element(&roots,i).map_err(|e|e.to_string())?;
            let item = JByteArray::from(item);
            if env.get_array_length(&item).map_err(|e|e.to_string())? > 128*1024 {
                return Err("Certificate size limit".into());
            }
            certificates.push(env.convert_byte_array(&item).map_err(|e|e.to_string())?);
            env.delete_local_ref(item).map_err(|e|e.to_string())?;
        }
        inspect(bytes,password,certificates)
    }));
    let value = match result {
        Ok(Ok(v)) => v, Ok(Err(e)) => json!({"error":e}),
        Err(_) => json!({"error":"Native verification failed"}),
    };
    env.new_string(value.to_string()).map(|s|s.into_raw()).unwrap_or(std::ptr::null_mut())
}
