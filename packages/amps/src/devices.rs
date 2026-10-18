//! Saved physical graph nodes. Endpoint IDs are machine-local, never defaults.
use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
	Input,
	Output,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Binding {
	pub id: String,
	pub name: String,
	pub direction: Direction,
	pub endpoint_id: String,
}

pub fn validate(devices: &[Binding]) -> Result<()> {
	if devices.len() > 16 {
		bail!("At most sixteen additional physical devices are supported");
	}
	let mut ids = BTreeSet::new();
	let mut endpoints = BTreeSet::new();
	for d in devices {
		if !d.id.starts_with("device-")
			|| d.id.len() > 80
			|| d.id.len() < 8
			|| !d.id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
		{
			bail!("Invalid physical node identifier");
		}
		if d.name.trim().is_empty() || d.name.len() > 160 || d.name.chars().any(char::is_control) {
			bail!("Device label must contain 1–160 printable characters");
		}
		if d.endpoint_id.trim().is_empty() || d.endpoint_id.len() > 512 {
			bail!("A physical node needs an explicit endpoint ID");
		}
		if !ids.insert(&d.id) || !endpoints.insert(d.endpoint_id.to_ascii_lowercase()) {
			bail!("That physical device is already in the graph");
		}
	}
	Ok(())
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn bindings_require_unique_explicit_identities() {
		let d = Binding {
			id: "device-test".into(),
			name: "Headphones".into(),
			direction: Direction::Output,
			endpoint_id: "fixture-output".into(),
		};
		assert!(validate(std::slice::from_ref(&d)).is_ok());
		assert!(validate(&[d.clone(), d.clone()]).is_err());
		let mut bad = d.clone();
		bad.id = "monitor".into();
		assert!(validate(&[bad]).is_err());
		let mut bad = d;
		bad.endpoint_id.clear();
		assert!(validate(&[bad]).is_err());
	}
}
