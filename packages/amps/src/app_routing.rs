use std::{collections::HashSet, ffi::c_void, mem::MaybeUninit};

use anyhow::{anyhow, bail, Context, Result};
use tracing::{debug, info, warn};
use wasapi::{DeviceEnumerator, Direction as WasapiDirection};
use windows::{
	core::{
		IInspectable, IInspectable_Vtbl, IUnknown, IUnknown_Vtbl, Interface, GUID, HRESULT, HSTRING,
		PCWSTR,
	},
	Win32::{
		Foundation::{CloseHandle, HANDLE},
		Media::Audio::{
			eCapture, eCommunications, eConsole, eMultimedia, eRender, EDataFlow, ERole,
			Endpoints::IAudioEndpointVolume, IMMDeviceEnumerator, MMDeviceEnumerator,
		},
		System::{
			Com::{CoCreateInstance, CLSCTX_ALL},
			Diagnostics::ToolHelp::{
				CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
				TH32CS_SNAPPROCESS,
			},
			WinRT::{RoGetActivationFactory, RoInitialize, RO_INIT_MULTITHREADED},
		},
	},
};

use crate::{AppRoute, Config};

const POLICY_CLASS: &str = "Windows.Media.Internal.AudioPolicyConfig";
const MMDEVAPI_PREFIX: &str = r"\\?\SWD#MMDEVAPI#";
const RENDER_SUFFIX: &str = "#{e6327cad-dcec-4949-ae8a-991e976a79d2}";
const CAPTURE_SUFFIX: &str = "#{2eef81be-33fa-4800-9670-1cd474972c3f}";

const POLICY_CONFIG_CLIENT: GUID = GUID::from_u128(0x870af99c_171d_4f9e_af0d_e63df40c2bc9);

#[repr(transparent)]
#[derive(Clone, PartialEq, Eq)]
struct PolicyConfig(IUnknown);

unsafe impl Interface for PolicyConfig {
	type Vtable = PolicyConfigVtable;
	const IID: GUID = GUID::from_u128(0xf8679f50_850a_41cf_9c72_430f290290c8);
}

#[repr(C)]
#[allow(non_snake_case)]
struct PolicyConfigVtable {
	base__: IUnknown_Vtbl,
	__incomplete__GetMixFormat: usize,
	__incomplete__GetDeviceFormat: usize,
	__incomplete__ResetDeviceFormat: usize,
	__incomplete__SetDeviceFormat: usize,
	__incomplete__GetProcessingPeriod: usize,
	__incomplete__SetProcessingPeriod: usize,
	__incomplete__GetShareMode: usize,
	__incomplete__SetShareMode: usize,
	__incomplete__GetPropertyValue: usize,
	__incomplete__SetPropertyValue: usize,
	SetDefaultEndpoint:
		unsafe extern "system" fn(this: *mut c_void, device_id: PCWSTR, role: ERole) -> HRESULT,
	__incomplete__SetEndpointVisibility: usize,
}

pub(crate) struct GlobalAudioDefaults {
	policy: PolicyConfig,
	game: String,
	comms: String,
	clean_mic: String,
}

impl GlobalAudioDefaults {
	pub(crate) fn new(config: &Config) -> Result<Self> {
		let _ = wasapi::initialize_mta();
		let enumerator =
			DeviceEnumerator::new().context("could not enumerate default audio endpoint IDs")?;
		let policy: PolicyConfig =
			unsafe { CoCreateInstance(&POLICY_CONFIG_CLIENT, None, CLSCTX_ALL) }
				.context("Windows global audio policy API is unavailable")?;
		Ok(Self {
			policy,
			game: resolve_endpoint_id(&enumerator, WasapiDirection::Render, &config.cables.game)?,
			comms: resolve_endpoint_id(&enumerator, WasapiDirection::Render, &config.cables.comms)?,
			clean_mic: resolve_endpoint_id(
				&enumerator,
				WasapiDirection::Capture,
				&config.cables.clean_mic,
			)?,
		})
	}

	pub(crate) fn enforce_outputs(&self) -> Result<()> {
		for role in [eConsole, eMultimedia] {
			self.set(&self.game, role)?;
		}
		self.set(&self.comms, eCommunications)
	}

	pub(crate) fn enforce_inputs(&self) -> Result<()> {
		for role in [eConsole, eMultimedia, eCommunications] {
			self.set(&self.clean_mic, role)?;
		}
		Ok(())
	}

	fn set(&self, endpoint_id: &str, role: ERole) -> Result<()> {
		let endpoint = HSTRING::from(endpoint_id);
		unsafe {
			(self.policy.vtable().SetDefaultEndpoint)(
				self.policy.as_raw(),
				PCWSTR(endpoint.as_ptr()),
				role,
			)
			.ok()
		}
		.with_context(|| format!("could not set Windows audio role {role:?} to {endpoint_id}"))
	}
}

pub(crate) fn select_output(selector: &str) -> Result<()> {
	let endpoint_id = resolved_endpoint_id(selector, WasapiDirection::Render)?;
	select_endpoint(
		&endpoint_id,
		WasapiDirection::Render,
		&[eConsole, eMultimedia],
	)?;
	info!(
		endpoint = selector,
		"selected temporary Windows playback endpoint"
	);
	Ok(())
}

pub(crate) fn select_input(selector: &str) -> Result<()> {
	let endpoint_id = resolved_endpoint_id(selector, WasapiDirection::Capture)?;
	ensure_capture_endpoint_ready(&endpoint_id)?;
	select_endpoint(
		&endpoint_id,
		WasapiDirection::Capture,
		&[eConsole, eMultimedia, eCommunications],
	)?;
	info!(
		endpoint = selector,
		"selected temporary Windows recording endpoint"
	);
	Ok(())
}

pub(crate) fn ensure_capture_endpoint_ready(endpoint_id: &str) -> Result<()> {
	ensure_endpoint_ready(endpoint_id, "capture")
}

pub(crate) fn ensure_capture_endpoint_selector_ready(selector: &str) -> Result<()> {
	let endpoint_id = resolved_endpoint_id(selector, WasapiDirection::Capture)?;
	ensure_capture_endpoint_ready(&endpoint_id)
}

fn ensure_endpoint_ready(endpoint_id: &str, kind: &str) -> Result<()> {
	let _ = wasapi::initialize_mta();
	let enumerator: IMMDeviceEnumerator =
		unsafe { CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL) }
			.with_context(|| format!("could not enumerate Windows {kind} endpoint volume"))?;
	let id = HSTRING::from(endpoint_id);
	let device = unsafe { enumerator.GetDevice(PCWSTR(id.as_ptr())) }
		.with_context(|| format!("could not open {kind} endpoint {endpoint_id}"))?;
	let volume: IAudioEndpointVolume = unsafe { device.Activate(CLSCTX_ALL, None) }
		.with_context(|| format!("could not open {kind} volume for {endpoint_id}"))?;
	let muted = unsafe { volume.GetMute() }
		.with_context(|| format!("could not inspect {kind} mute for {endpoint_id}"))?
		.as_bool();
	let level = unsafe { volume.GetMasterVolumeLevelScalar() }
		.with_context(|| format!("could not inspect {kind} level for {endpoint_id}"))?;
	if muted {
		unsafe { volume.SetMute(false, std::ptr::null()) }
			.with_context(|| format!("could not unmute {kind} endpoint {endpoint_id}"))?;
	}
	if level <= f32::EPSILON {
		unsafe { volume.SetMasterVolumeLevelScalar(1.0, std::ptr::null()) }
			.with_context(|| format!("could not restore {kind} level for {endpoint_id}"))?;
	}
	if muted || level <= f32::EPSILON {
		info!(
			endpoint = endpoint_id,
			endpoint_kind = kind,
			previous_level = level,
			was_muted = muted,
			"restored selected physical endpoint"
		);
	}
	Ok(())
}

fn resolved_endpoint_id(selector: &str, direction: WasapiDirection) -> Result<String> {
	let _ = wasapi::initialize_mta();
	let enumerator = DeviceEnumerator::new().context("could not enumerate Windows endpoint IDs")?;
	resolve_endpoint_id(&enumerator, direction, selector)
}

fn select_endpoint(selector: &str, direction: WasapiDirection, roles: &[ERole]) -> Result<()> {
	let endpoint_id = resolved_endpoint_id(selector, direction)?;
	let policy: PolicyConfig = unsafe { CoCreateInstance(&POLICY_CONFIG_CLIENT, None, CLSCTX_ALL) }
		.context("Windows global audio policy API is unavailable")?;
	let endpoint = HSTRING::from(&endpoint_id);
	for &role in roles {
		unsafe {
			(policy.vtable().SetDefaultEndpoint)(policy.as_raw(), PCWSTR(endpoint.as_ptr()), role).ok()
		}
		.with_context(|| format!("could not set Windows audio role {role:?} to {endpoint_id}"))?;
	}
	Ok(())
}

pub(crate) fn process_is_running(name: &str) -> Result<bool> {
	Ok(enumerate_processes()?
		.into_iter()
		.any(|(_, process)| process.eq_ignore_ascii_case(name)))
}

#[repr(transparent)]
#[derive(Clone, PartialEq, Eq)]
struct AudioPolicyConfigFactory21H2(IInspectable);

unsafe impl Interface for AudioPolicyConfigFactory21H2 {
	type Vtable = AudioPolicyConfigFactoryVtable;
	const IID: GUID = GUID::from_u128(0xab3d4648_e242_459f_b02f_541c70306324);
}

#[repr(transparent)]
#[derive(Clone, PartialEq, Eq)]
struct AudioPolicyConfigFactoryDownlevel(IInspectable);

unsafe impl Interface for AudioPolicyConfigFactoryDownlevel {
	type Vtable = AudioPolicyConfigFactoryVtable;
	const IID: GUID = GUID::from_u128(0x2a59116d_6c4f_45e0_a74f_707e3fef9258);
}

#[repr(C)]
#[allow(non_snake_case)]
struct AudioPolicyConfigFactoryVtable {
	base__: IInspectable_Vtbl,
	__incomplete__add_CtxVolumeChange: usize,
	__incomplete__remove_CtxVolumeChanged: usize,
	__incomplete__add_RingerVibrateStateChanged: usize,
	__incomplete__remove_RingerVibrateStateChange: usize,
	__incomplete__SetVolumeGroupGainForId: usize,
	__incomplete__GetVolumeGroupGainForId: usize,
	__incomplete__GetActiveVolumeGroupForEndpointId: usize,
	__incomplete__GetVolumeGroupsForEndpoint: usize,
	__incomplete__GetCurrentVolumeContext: usize,
	__incomplete__SetVolumeGroupMuteForId: usize,
	__incomplete__GetVolumeGroupMuteForId: usize,
	__incomplete__SetRingerVibrateState: usize,
	__incomplete__GetRingerVibrateState: usize,
	__incomplete__SetPreferredChatApplication: usize,
	__incomplete__ResetPreferredChatApplication: usize,
	__incomplete__GetPreferredChatApplication: usize,
	__incomplete__GetCurrentChatApplications: usize,
	__incomplete__add_ChatContextChanged: usize,
	__incomplete__remove_ChatContextChanged: usize,
	SetPersistedDefaultAudioEndpoint: unsafe extern "system" fn(
		this: *mut c_void,
		process_id: u32,
		flow: EDataFlow,
		role: ERole,
		device_id: MaybeUninit<HSTRING>,
	) -> HRESULT,
	GetPersistedDefaultAudioEndpoint: usize,
	ClearAllPersistedApplicationDefaultEndpoints: usize,
}

enum PolicyFactory {
	Current(AudioPolicyConfigFactory21H2),
	Downlevel(AudioPolicyConfigFactoryDownlevel),
}

impl PolicyFactory {
	fn activate() -> Result<Self> {
		let _ = unsafe { RoInitialize(RO_INIT_MULTITHREADED) };
		let class = HSTRING::from(POLICY_CLASS);
		if let Ok(factory) = unsafe { RoGetActivationFactory::<AudioPolicyConfigFactory21H2>(&class) }
		{
			return Ok(Self::Current(factory));
		}
		if let Ok(factory) =
			unsafe { RoGetActivationFactory::<AudioPolicyConfigFactoryDownlevel>(&class) }
		{
			return Ok(Self::Downlevel(factory));
		}
		bail!("Windows per-application audio routing API is unavailable")
	}

	fn set(&self, process_id: u32, flow: EDataFlow, endpoint_id: &str) -> Result<()> {
		let endpoint = HSTRING::from(policy_endpoint_id(endpoint_id, flow));
		match self {
			Self::Current(factory) => set_app_roles(factory, process_id, flow, &endpoint),
			Self::Downlevel(factory) => set_app_roles(factory, process_id, flow, &endpoint),
		}
	}
}

fn set_app_roles<T>(factory: &T, process_id: u32, flow: EDataFlow, endpoint: &HSTRING) -> Result<()>
where
	T: Interface<Vtable = AudioPolicyConfigFactoryVtable>,
{
	// This private Windows API only accepts processes that currently own an audio
	// session. Multi-process apps such as Discord therefore reject their shell,
	// renderer, and GPU PIDs with E_INVALIDARG while accepting the audio-service
	// PID. Match EarTrumpet's supported roles and consider the process routable
	// when either role succeeds.
	let mut routed = false;
	let mut failures = Vec::new();
	for role in [eMultimedia, eConsole] {
		let result = unsafe {
			(factory.vtable().SetPersistedDefaultAudioEndpoint)(
				factory.as_raw(),
				process_id,
				flow,
				role,
				// WinRT passes an HSTRING handle by value without transferring
				// ownership. Match windows-rs generated bindings instead of cloning
				// into MaybeUninit, which would leak one reference per attempt.
				std::mem::transmute_copy(endpoint),
			)
			.ok()
		};
		match result {
			Ok(()) => routed = true,
			Err(error) => failures.push(format!("{role:?}: {error}")),
		}
	}
	if !routed {
		bail!(
			"Windows rejected process {process_id} for every app-audio role ({})",
			failures.join(", ")
		);
	}
	Ok(())
}

struct CableEndpointIds {
	game: String,
	comms: String,
	music: String,
	chatgpt_render: String,
	chatgpt_in: String,
	comms_send: String,
	clean_mic: String,
}

pub(crate) fn print_cable_endpoints(config: &Config) -> Result<()> {
	let _ = wasapi::initialize_mta();
	let enumerator = DeviceEnumerator::new().context("could not enumerate audio endpoint IDs")?;
	for (name, direction, selector) in [
		(
			"game",
			WasapiDirection::Capture,
			config.cables.game.as_str(),
		),
		(
			"comms",
			WasapiDirection::Capture,
			config.cables.comms.as_str(),
		),
		(
			"music",
			WasapiDirection::Capture,
			config.cables.music.as_str(),
		),
		(
			"chatgpt",
			WasapiDirection::Capture,
			config.cables.chatgpt.as_str(),
		),
		(
			"clean_mic",
			WasapiDirection::Capture,
			config.cables.clean_mic.as_str(),
		),
		(
			"chatgpt_in",
			WasapiDirection::Capture,
			config.cables.chatgpt_in.as_str(),
		),
		(
			"comms_send",
			WasapiDirection::Capture,
			config.cables.comms_send.as_str(),
		),
	] {
		println!(
			"{name}\t{}",
			resolve_endpoint_id(&enumerator, direction, selector)?
		);
	}
	Ok(())
}

pub(crate) struct AppRouter {
	factory: PolicyFactory,
	routes: Vec<AppRoute>,
	endpoints: CableEndpointIds,
	seen: HashSet<u32>,
}

impl AppRouter {
	pub(crate) fn new(config: &Config) -> Result<Self> {
		let _ = wasapi::initialize_mta();
		let enumerator = DeviceEnumerator::new().context("could not enumerate audio endpoint IDs")?;
		let endpoints = CableEndpointIds {
			game: resolve_endpoint_id(&enumerator, WasapiDirection::Render, &config.cables.game)?,
			comms: resolve_endpoint_id(&enumerator, WasapiDirection::Render, &config.cables.comms)?,
			music: resolve_endpoint_id(&enumerator, WasapiDirection::Render, &config.cables.music)?,
			chatgpt_render: resolve_endpoint_id(
				&enumerator,
				WasapiDirection::Render,
				&config.cables.chatgpt,
			)?,
			chatgpt_in: resolve_endpoint_id(
				&enumerator,
				WasapiDirection::Capture,
				&config.cables.chatgpt_in,
			)?,
			comms_send: resolve_endpoint_id(
				&enumerator,
				WasapiDirection::Capture,
				&config.cables.comms_send,
			)?,
			clean_mic: resolve_endpoint_id(
				&enumerator,
				WasapiDirection::Capture,
				&config.cables.clean_mic,
			)?,
		};
		Ok(Self {
			factory: PolicyFactory::activate()?,
			routes: config.routes.clone(),
			endpoints,
			seen: HashSet::new(),
		})
	}

	pub(crate) fn reconcile(&mut self) -> Result<()> {
		let processes = enumerate_processes()?;
		let live_pids = processes
			.iter()
			.map(|(pid, _)| *pid)
			.collect::<HashSet<_>>();
		self.seen.retain(|pid| live_pids.contains(pid));

		for (process_id, executable) in processes {
			if self.seen.contains(&process_id) {
				continue;
			}
			let Some(route) = self
				.routes
				.iter()
				.find(|route| route.process.eq_ignore_ascii_case(&executable))
			else {
				continue;
			};
			let mut output_routed = route.output.is_none();
			let mut input_routed = route.input.is_none();
			if let Some(output) = &route.output {
				let endpoint = match output.as_str() {
					"game" => &self.endpoints.game,
					"comms" => &self.endpoints.comms,
					"music" => &self.endpoints.music,
					"chatgpt" => &self.endpoints.chatgpt_render,
					_ => unreachable!(),
				};
				match self.factory.set(process_id, eRender, endpoint) {
					Ok(()) => output_routed = true,
					Err(error) => debug!(
						%process_id,
						%executable,
						%error,
						"process does not currently own a routable render session"
					),
				}
			}
			if let Some(input) = &route.input {
				let endpoint = match input.as_str() {
					"clean_mic" => &self.endpoints.clean_mic,
					"chatgpt_in" => &self.endpoints.chatgpt_in,
					"comms_send" => &self.endpoints.comms_send,
					_ => unreachable!(),
				};
				match self.factory.set(process_id, eCapture, endpoint) {
					Ok(()) => input_routed = true,
					Err(error) => debug!(
						%process_id,
						%executable,
						%error,
						"process does not currently own a routable capture session"
					),
				}
			}
			if output_routed && input_routed {
				self.seen.insert(process_id);
				info!(%process_id, %executable, output = ?route.output, input = ?route.input, %output_routed, %input_routed, "persisted app audio route");
			}
		}
		Ok(())
	}
}

fn resolve_endpoint_id(
	enumerator: &DeviceEnumerator,
	direction: WasapiDirection,
	selector: &str,
) -> Result<String> {
	let collection = enumerator.get_device_collection(&direction)?;
	let mut matches = Vec::new();
	for device in &collection {
		let device = device?;
		let name = device.get_friendlyname()?;
		let endpoint_id = device.get_id()?;
		if endpoint_id == selector {
			return Ok(endpoint_id);
		}
		if name
			.to_ascii_lowercase()
			.contains(&selector.to_ascii_lowercase())
		{
			matches.push((name, endpoint_id));
		}
	}
	match matches.len() {
		0 => Err(anyhow!("no endpoint ID contains {selector:?}")),
		1 => Ok(matches.pop().unwrap().1),
		_ => Err(anyhow!(
			"endpoint selector {selector:?} is ambiguous: {}",
			matches
				.into_iter()
				.map(|item| item.0)
				.collect::<Vec<_>>()
				.join(", ")
		)),
	}
}

fn policy_endpoint_id(endpoint_id: &str, flow: EDataFlow) -> String {
	let suffix = if flow == eCapture {
		CAPTURE_SUFFIX
	} else {
		RENDER_SUFFIX
	};
	format!("{MMDEVAPI_PREFIX}{endpoint_id}{suffix}")
}

fn enumerate_processes() -> Result<Vec<(u32, String)>> {
	let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) }
		.context("could not snapshot Windows processes")?;
	let _guard = Snapshot(snapshot);
	let mut entry = PROCESSENTRY32W {
		dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
		..Default::default()
	};
	let mut processes = Vec::new();
	if unsafe { Process32FirstW(snapshot, &mut entry) }.is_err() {
		return Ok(processes);
	}
	loop {
		let length = entry
			.szExeFile
			.iter()
			.position(|ch| *ch == 0)
			.unwrap_or(entry.szExeFile.len());
		let executable = String::from_utf16_lossy(&entry.szExeFile[..length]);
		processes.push((entry.th32ProcessID, executable));
		if unsafe { Process32NextW(snapshot, &mut entry) }.is_err() {
			break;
		}
	}
	debug!(
		count = processes.len(),
		"enumerated processes for app routing"
	);
	Ok(processes)
}

struct Snapshot(HANDLE);

impl Drop for Snapshot {
	fn drop(&mut self) {
		if let Err(err) = unsafe { CloseHandle(self.0) } {
			warn!(%err, "could not close process snapshot");
		}
	}
}
