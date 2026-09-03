use std::{
	ffi::{c_char, c_void, CString},
	path::{Path, PathBuf},
};

use anyhow::{anyhow, bail, Context, Result};
use libloading::{os::windows::Library as WindowsLibrary, Library};

const SDK_DIRECTORY: &str = "NVIDIA Corporation\\NVIDIA Audio Effects SDK";
const DLL_NAME: &str = "NVAudioEffects.dll";
const MODEL_NAME: &str = "denoiser_48k.trtpkg";
// LoadLibraryExW normally applies the process-wide DLL search policy to a
// dependency named by an explicitly loaded module. NVIDIA ships CUDA,
// TensorRT, and OpenSSL dependencies beside NVAudioEffects.dll, so use the
// documented altered search path to resolve that private runtime as a unit.
const LOAD_WITH_ALTERED_SEARCH_PATH: u32 = 0x0000_0008;

type NvAfxStatus = i32;
type NvAfxHandle = *mut c_void;
type CreateEffect = unsafe extern "C" fn(*const c_char, *mut NvAfxHandle) -> NvAfxStatus;
type DestroyEffect = unsafe extern "C" fn(NvAfxHandle) -> NvAfxStatus;
type SetString = unsafe extern "C" fn(NvAfxHandle, *const c_char, *const c_char) -> NvAfxStatus;
type SetFloat = unsafe extern "C" fn(NvAfxHandle, *const c_char, f32) -> NvAfxStatus;
type GetU32 = unsafe extern "C" fn(NvAfxHandle, *const c_char, *mut u32) -> NvAfxStatus;
type LoadEffect = unsafe extern "C" fn(NvAfxHandle) -> NvAfxStatus;
type RunEffect =
	unsafe extern "C" fn(NvAfxHandle, *const *const f32, *mut *mut f32, u32, u32) -> NvAfxStatus;

pub(crate) struct NvidiaAfx {
	_library: Library,
	handle: NvAfxHandle,
	destroy: DestroyEffect,
	run: RunEffect,
	frame_samples: usize,
}

impl NvidiaAfx {
	pub(crate) fn new(intensity: u8) -> Result<Self> {
		let sdk_root = sdk_root();
		let dll_path = sdk_root.join(DLL_NAME);
		let model_path = sdk_root.join("models").join(MODEL_NAME);
		if !dll_path.is_file() || !model_path.is_file() {
			bail!(
				"NVIDIA Audio Effects 1.6.1 runtime is unavailable at {}",
				sdk_root.display()
			);
		}

		let library =
			unsafe { WindowsLibrary::load_with_flags(&dll_path, LOAD_WITH_ALTERED_SEARCH_PATH) }
				.map(Library::from)
				.with_context(|| format!("could not load {}", dll_path.display()))?;
		let create: CreateEffect = symbol(&library, b"NvAFX_CreateEffect\0")?;
		let destroy: DestroyEffect = symbol(&library, b"NvAFX_DestroyEffect\0")?;
		let set_string: SetString = symbol(&library, b"NvAFX_SetString\0")?;
		let set_float: SetFloat = symbol(&library, b"NvAFX_SetFloat\0")?;
		let get_u32: GetU32 = symbol(&library, b"NvAFX_GetU32\0")?;
		let load: LoadEffect = symbol(&library, b"NvAFX_Load\0")?;
		let run: RunEffect = symbol(&library, b"NvAFX_Run\0")?;

		let effect = CString::new("denoiser")?;
		let mut handle = std::ptr::null_mut();
		check(
			unsafe { create(effect.as_ptr(), &mut handle) },
			"NvAFX_CreateEffect",
		)?;
		if handle.is_null() {
			bail!("NvAFX_CreateEffect returned a null denoiser handle");
		}

		let initialized = (|| -> Result<usize> {
			let model_parameter = CString::new("model_path")?;
			let model = path_cstring(&model_path)?;
			check(
				unsafe { set_string(handle, model_parameter.as_ptr(), model.as_ptr()) },
				"NvAFX_SetString(model_path)",
			)?;

			let intensity_parameter = CString::new("intensity_ratio")?;
			check(
				unsafe {
					set_float(
						handle,
						intensity_parameter.as_ptr(),
						intensity.min(100) as f32 / 100.0,
					)
				},
				"NvAFX_SetFloat(intensity_ratio)",
			)?;
			check(unsafe { load(handle) }, "NvAFX_Load")?;

			let sample_rate = get_parameter(get_u32, handle, "input_sample_rate")?;
			let output_rate = get_parameter(get_u32, handle, "output_sample_rate")?;
			let input_channels = get_parameter(get_u32, handle, "num_input_channels")?;
			let output_channels = get_parameter(get_u32, handle, "num_output_channels")?;
			let input_samples = get_parameter(get_u32, handle, "num_input_samples_per_frame")?;
			let output_samples = get_parameter(get_u32, handle, "num_output_samples_per_frame")?;
			if sample_rate != 48_000 || output_rate != 48_000 {
				bail!(
					"NVIDIA AFX denoiser selected {sample_rate}/{output_rate} Hz instead of 48000 Hz"
				);
			}
			if input_channels != 1 || output_channels != 1 {
				bail!("NVIDIA AFX denoiser selected {input_channels}/{output_channels} channels instead of mono");
			}
			if input_samples == 0 || input_samples != output_samples {
				bail!(
					"NVIDIA AFX denoiser reported invalid frame sizes {input_samples}/{output_samples}"
				);
			}
			Ok(input_samples as usize)
		})();

		let frame_samples = match initialized {
			Ok(frame_samples) => frame_samples,
			Err(error) => {
				unsafe {
					let _ = destroy(handle);
				}
				return Err(error);
			}
		};

		Ok(Self {
			_library: library,
			handle,
			destroy,
			run,
			frame_samples,
		})
	}

	pub(crate) fn frame_samples(&self) -> usize {
		self.frame_samples
	}

	pub(crate) fn process(&mut self, input: &[f32], output: &mut [f32]) -> Result<()> {
		if input.len() != self.frame_samples || output.len() != self.frame_samples {
			bail!(
				"NVIDIA AFX expected {} samples but received {}/{}",
				self.frame_samples,
				input.len(),
				output.len()
			);
		}
		let input_channels = [input.as_ptr()];
		let mut output_channels = [output.as_mut_ptr()];
		check(
			unsafe {
				(self.run)(
					self.handle,
					input_channels.as_ptr(),
					output_channels.as_mut_ptr(),
					self.frame_samples as u32,
					1,
				)
			},
			"NvAFX_Run",
		)
	}
}

impl Drop for NvidiaAfx {
	fn drop(&mut self) {
		if !self.handle.is_null() {
			unsafe {
				let _ = (self.destroy)(self.handle);
			}
			self.handle = std::ptr::null_mut();
		}
	}
}

pub(crate) fn runtime_available() -> bool {
	let root = sdk_root();
	root.join(DLL_NAME).is_file() && root.join("models").join(MODEL_NAME).is_file()
}

fn sdk_root() -> PathBuf {
	std::env::var_os("NVAFX_SDK_DIR")
		.filter(|value| !value.is_empty())
		.map(PathBuf::from)
		.or_else(|| {
			std::env::var_os("ProgramFiles")
				.map(PathBuf::from)
				.map(|root| root.join(SDK_DIRECTORY))
		})
		.unwrap_or_else(|| PathBuf::from(r"C:\Program Files").join(SDK_DIRECTORY))
}

fn path_cstring(path: &Path) -> Result<CString> {
	let path = path.to_str().ok_or_else(|| {
		anyhow!(
			"NVIDIA AFX model path is not valid Unicode: {}",
			path.display()
		)
	})?;
	CString::new(path).context("NVIDIA AFX model path contains an embedded NUL")
}

fn get_parameter(get_u32: GetU32, handle: NvAfxHandle, parameter: &str) -> Result<u32> {
	let parameter = CString::new(parameter)?;
	let mut value = 0_u32;
	check(
		unsafe { get_u32(handle, parameter.as_ptr(), &mut value) },
		"NvAFX_GetU32",
	)?;
	Ok(value)
}

fn check(status: NvAfxStatus, operation: &str) -> Result<()> {
	if status == 0 {
		return Ok(());
	}
	bail!(
		"{operation} failed with NVIDIA AFX status {status} ({})",
		status_name(status)
	)
}

fn status_name(status: NvAfxStatus) -> &'static str {
	match status {
		1 => "failed",
		2 => "invalid handle",
		3 => "invalid parameter",
		4 => "immutable parameter",
		5 => "insufficient data",
		6 => "effect unavailable",
		7 => "output buffer too small",
		8 => "model load failed",
		9 => "32-bit server not registered",
		10 => "32-bit COM error",
		11 => "unsupported GPU",
		12 => "CUDA context creation failed",
		_ => "unknown",
	}
}

fn symbol<T: Copy>(library: &Library, name: &[u8]) -> Result<T> {
	unsafe { library.get::<T>(name).map(|symbol| *symbol) }.with_context(|| {
		format!(
			"NVIDIA AFX export {} is unavailable",
			String::from_utf8_lossy(name)
		)
	})
}
