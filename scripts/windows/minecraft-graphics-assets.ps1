$script:MinecraftShaderPack = "ComplementaryUnbound_r5.8.1.zip"
$script:MinecraftDefaultResourcePack = "Pixlli V57 26.3-1.13 128x.zip"
$script:MinecraftAnimationResourcePack = "FreshAnimations_v1.10.5.zip"
$script:MinecraftEmissiveResourcePack = "FullEmissive3.4.2.zip"

$script:MinecraftDistantHorizonsFile = [ordered]@{
	path = "mods/DistantHorizons-3.2.0-b-26.2-fabric-neoforge.jar"
	hashes = [ordered]@{
		sha1 = "3646a34691c0857a64614bb7ecd344d8b22b117a"
		sha512 = "c1b8857776a002c2232887d891bd49195f3c3127a7abe1242376ad20371e31554d8ba6c7c92a195b70782cad94fe970941487f2af530988d9b8819455c859e72"
	}
	env = [ordered]@{ client = "required"; server = "unsupported" }
	downloads = @("https://cdn.modrinth.com/data/uCdwusMi/versions/gBf0SaV1/DistantHorizons-3.2.0-b-26.2-fabric-neoforge.jar")
	fileSize = 29705395
}

$script:MinecraftGraphicsFiles = @(
	$MinecraftDistantHorizonsFile,
	[ordered]@{
		path = "mods/iris-fabric-1.11.2+mc26.2.jar"
		hashes = [ordered]@{
			sha1 = "f7d526b1062c4bfe2567113cf933d1de26eddd3f"
			sha512 = "c1b46bcd1a0068deab3ae364a7229d31e27b7d45aea960e47503b8514354426badf83f354529db35d83e6b55727a53895fb9f13085e51d8148ee6765affac924"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/YL57xq9U/versions/oaD6KQls/iris-fabric-1.11.2%2Bmc26.2.jar")
		fileSize = 2820763
	},
	[ordered]@{
		path = "mods/sodium-fabric-0.9.1+mc26.2.jar"
		hashes = [ordered]@{
			sha1 = "14f3388694fa77f870d28262f74562de67eabcbe"
			sha512 = "627fbf9625a4b94693c789c84a0686ffe558c0b1ecbeccf2602a903caafa9e126548b644282aa9c391dc798930d378724a383bea6b4397c5294d59ba5c0a6936"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/AANobbMI/versions/2Yom1N68/sodium-fabric-0.9.1%2Bmc26.2.jar")
		fileSize = 1834384
	},
	[ordered]@{
		path = "mods/fabric-api-0.157.0+26.2.jar"
		hashes = [ordered]@{
			sha1 = "0deb9d110def35ebcaf5f15a9e6c8b8e85685319"
			sha512 = "4ebec489f2b2ce621ebebb2d1b7e9714b6fd288ebdb4e287d767cde57612cf1d3d1d4f51daf7e7ec9541fa146df6bde4978ab98a29637ced6d9bc2f3c4217650"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/P7dR8mSH/versions/vmQp7ixA/fabric-api-0.157.0%2B26.2.jar")
		fileSize = 2533297
	},
	[ordered]@{
		path = "mods/continuity-3.0.1+26.2.jar"
		hashes = [ordered]@{
			sha1 = "8fa8bc108e84158b0828a4aa59bf906d31676eec"
			sha512 = "3436b39fcdddce87f8eda0f35095067477636df2667195df3cb8eae2d002d3ff8ac44de97332668ee50e13ad91be5c532cbc6121878f1e6c904c98c1c9c67c0b"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/1IjD5062/versions/mgUN5Xz2/continuity-3.0.1%2B26.2.jar")
		fileSize = 1040013
	},
	[ordered]@{
		path = "mods/entity_model_features-3.2.6-26.2-fabric.jar"
		hashes = [ordered]@{
			sha1 = "47862c653e419aa6741338b795db841f1086a643"
			sha512 = "9296b5755839062067c9e5e561b8248709c5f9aade53a9eb0c87e0d0dc743f83f1a6b5776dbe1c33c85b0b1a3355544b0da53b0bcdcee5dccc02d6576cb9ef31"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/4I1XuqiY/versions/xQeW3qQB/entity_model_features-3.2.6-26.2-fabric.jar")
		fileSize = 587342
	},
	[ordered]@{
		path = "mods/entity_texture_features-7.1.1-26.2-fabric.jar"
		hashes = [ordered]@{
			sha1 = "2d09a60630e8f25a25d9c06d87684c74a843caac"
			sha512 = "4acd478923fac5300fb43cbcc3b6a7501fee473491ee416b5d5a1203bdb8ceeaed04ff34bd1730a9cbff7bc4497265ab129f9eee2ca1d37a70c463203b1a8c20"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/BVzZfTc1/versions/HLCBKYFD/entity_texture_features-7.1.1-26.2-fabric.jar")
		fileSize = 762131
	},
	[ordered]@{
		path = "mods/sound-physics-remastered-fabric-1.5.1+26.2.jar"
		hashes = [ordered]@{
			sha1 = "63657ef05768d2a7a102549bc8ef5f5fc04e2fc4"
			sha512 = "5c3d11462848c15ddfd4b854c998ed55c13e4bcd033a9f01acbea56d55079f4795c67321af803cc1b1b0e0d81dfd6750532294c932e921288858c0d9ea06f97e"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/qyVF9oeo/versions/d8iioMMp/sound-physics-remastered-fabric-1.5.1%2B26.2.jar")
		fileSize = 201669
	},
	[ordered]@{
		path = "mods/lambdynamiclights-4.12.2+26.2.jar"
		hashes = [ordered]@{
			sha1 = "0667b3e1d203a54a0fcede02d97fc3b9f384711c"
			sha512 = "3c2ab4028e47da4155e860c9449231d7b17e10dc6d9d110ab58dc621ab806fcc0b21741c73a671c0d72fb9ae5021792cea18f09b515180ae33e86c4008c3d139"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/yBW8D80W/versions/jBLH7Qy8/lambdynamiclights-4.12.2%2B26.2.jar")
		fileSize = 1348440
	},
	[ordered]@{
		path = "mods/ImmediatelyFast-Fabric-1.16.2+26.2.jar"
		hashes = [ordered]@{
			sha1 = "2d1cd27b0b570f908b665c02a35b49381b4c5ec1"
			sha512 = "5f7c9d7993bfe3654b4f384c23afd83c1adcc359b1fa669b20f29ffa41e4e3135a161c1fdf97c66c5fc513ec5fe63e757a46b6e183b7b93148a28412496c5a0b"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/5ZwdcRci/versions/uJHxuQxy/ImmediatelyFast-Fabric-1.16.2%2B26.2.jar")
		fileSize = 91422
	},
	[ordered]@{
		path = "mods/entityculling-fabric-1.10.5-mc26.2.jar"
		hashes = [ordered]@{
			sha1 = "f66f9d8cbb1f76466aaf45e46fb11b18207e3aef"
			sha512 = "338813c344a2d924abbaaf249da2b52f5e162bd92407f3099c6ff1bce1c1efecde9df80efcc7b4de3b3a0044cc5735b96594b04da4594bb26793459fc6c960a6"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/NNAgCjsB/versions/iiF6U3Ne/entityculling-fabric-1.10.5-mc26.2.jar")
		fileSize = 1583775
	},
	[ordered]@{
		path = "mods/ferritecore-9.0.0-fabric.jar"
		hashes = [ordered]@{
			sha1 = "eac76ff0f3753422c61b2c44487d0d195d88d4bc"
			sha512 = "d81fa97e11784c19d42f89c2f433831d007603dd7193cee45fa177e4a6a9c52b384b198586e04a0f7f63cd996fed713322578bde9a8db57e1188854ae5cbe584"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/uXXizFIs/versions/d5ddUdiB/ferritecore-9.0.0-fabric.jar")
		fileSize = 72677
	},
	[ordered]@{
		path = "mods/lithium-fabric-0.25.3+mc26.2.jar"
		hashes = [ordered]@{
			sha1 = "435ad0289209bb72195e7a423756a03f5dfa5a9a"
			sha512 = "148b638f3c6229fbaf487120a2344a0af5e411a5aa6533d5db9d75da0a8c0d8304f63eb4cca13f4d03b2c9b4c23d559dd74c1d832422ef8a3087bd005e62a8bd"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/gvQqBUqZ/versions/f7vZ0VWU/lithium-fabric-0.25.3%2Bmc26.2.jar")
		fileSize = 912850
	},
	[ordered]@{
		path = "mods/cloth-config-26.2.155.jar"
		hashes = [ordered]@{
			sha1 = "babcf16dbd15e09d326e21ffe85ab3f7d843ef9e"
			sha512 = "37b1e402f0df5a383656e21a38ee18cdd15cb4ba3fb62fbeba82ef4b959a4479fc32718ac0d9d154a7d9104c5f7315bfa67dbeced0b8ff240b8039d4848d5df1"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/9s6osm5g/versions/Nv3xnWXd/cloth-config-26.2.155.jar")
		fileSize = 1135186
	},
	[ordered]@{
		path = "mods/placeholder-api-3.1.0-beta.1+26.2.jar"
		hashes = [ordered]@{
			sha1 = "99b57ccc1d4323c4ef71887828dac25ce4ce2103"
			sha512 = "07b6fc802559d54ec6577f6e2788926ef391d755206c2bfb0528280977885cae4bc0c517d8a53eb6f34092015ebe6c41210627d255aa6504662daefa8fb76397"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/eXts2L7r/versions/NDqH16LT/placeholder-api-3.1.0-beta.1%2B26.2.jar")
		fileSize = 254973
	},
	[ordered]@{
		path = "mods/modmenu-20.0.1.jar"
		hashes = [ordered]@{
			sha1 = "8562dee49eae1a6bdd14b026be1b300aedb5ce0f"
			sha512 = "1aa297ab5e6fac71ad6af750fe6f8cd25281bd00c0340e5fe1c1e9d153d1198df03be1df55727a4a2116db97dcaad541d41754f3fc0063abfe4345b60f193fb4"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/mOgUt4GM/versions/njXb639R/modmenu-20.0.1.jar")
		fileSize = 614002
	},
	[ordered]@{
		path = "shaderpacks/$MinecraftShaderPack"
		hashes = [ordered]@{
			sha1 = "af656a33be2cbd217ea08986ad2cdd76f6bbfe1c"
			sha512 = "9098dd9e0c18b80f7aba2839cea33ce9a614d97665bbfcac87ccce6e4771667c41602d99088852cb1642ccab20b2ceff9b98af8f2e795bd0d3b90b7c9cbab914"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/R6NEzAwj/versions/VMHXIk50/ComplementaryUnbound_r5.8.1.zip")
		fileSize = 546928
	},
	[ordered]@{
		path = "resourcepacks/$MinecraftDefaultResourcePack"
		hashes = [ordered]@{
			sha1 = "3561d746c605979ba67ec4b17ee3aeaa6c77b4a7"
			sha512 = "2d9be848c68b15083edf8f1a5e64066a2b970a43e622e66e82c4e5971dc29a3a263351f38bdb111dacdd154134352f17ff7dda0a953ab2eedf5723c63ed563d9"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/E8fGzGhh/versions/w9CkPND8/Pixlli%20V57%2026.3-1.13%20128x.zip")
		fileSize = 154662941
	},
	[ordered]@{
		path = "resourcepacks/$MinecraftAnimationResourcePack"
		hashes = [ordered]@{
			sha1 = "0d069c5583d1dd4591e55ec5ff6dd0905f3f8615"
			sha512 = "f4f2a1d294c2e0afe245b6987fea4a84ff120f131a7f2cfb16779e9cc5d0a00b3d49bf1585ac827d6690c36421e8dda203b0c6e642bb0c6aa067c5921dd8dc30"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/50dA9Sha/versions/RGIzA5em/FreshAnimations_v1.10.5.zip")
		fileSize = 645816
	},
	[ordered]@{
		path = "resourcepacks/Patrix_26.2_32x_basic.zip"
		hashes = [ordered]@{
			sha1 = "f85d0f81e639f5a00b41ec3821c80c237d337c82"
			sha512 = "7ea43d9138bee7fb9561f45b2927ca907a9a83ac7eb8907c086db40c201e267fc19f32abc4e89ae1b3f320c8aac47380bddbabde4cf7786be6bc116ae79cf375"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/olO1TaXd/versions/jZHaNOzL/Patrix_26.2_32x_basic.zip")
		fileSize = 74272862
	},
	[ordered]@{
		path = "resourcepacks/ModernArch v3.0.6 [26.2] [128x].zip"
		hashes = [ordered]@{
			sha1 = "804c46b733ba12bebbf4e513d7c1c08f77bca246"
			sha512 = "ba117fb59999246292d9432f86973d83d85e1f9f6aa61f689792cba8461c8068565b93373be4c5f4486e8582062be772eacb760873485ed3a3f14c10854cda5a"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/J4cajZTT/versions/upDJFoyO/ModernArch%20v3.0.6%20%5B26.2%5D%20%5B128x%5D.zip")
		fileSize = 283386537
	},
	[ordered]@{
		path = "resourcepacks/$MinecraftEmissiveResourcePack"
		hashes = [ordered]@{
			sha1 = "d2effe9ff9f4c013625d3fe1f894ad0a73055b90"
			sha512 = "03c353366d58bcc6b4ff2a1c96cb442e666aadc30fa4e19fe6df5a909e5f274b733bbf9c079f3a0d9a1a49e72ecb2a8ed4cc99af0cc2db80cd0ec3d7068f063f"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/rfRHAjwQ/versions/qiQ3TMUe/FullEmissive3.4.2.zip")
		fileSize = 2810355
	},
	[ordered]@{
		path = "resourcepacks/GEO - v1.109.0.zip"
		hashes = [ordered]@{
			sha1 = "4e4f90f222db31ae941c8bdce0671de2aee3d2da"
			sha512 = "ef7f21cf0f468ed99aaba33c4a0144145a74ec6230eb4e934a80670544193b198282e0822fce800bc1338a2948c83b39fc197d54200cde575cf74ec17de283fe"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/l8XRSfMu/versions/QJKF44Tc/GEO%20-%20v1.109.0.zip")
		fileSize = 27316670
	},
	[ordered]@{
		path = "resourcepacks/rotrBLOCKS V87 [3D Foliage] 128x 26.2-1.13.zip"
		hashes = [ordered]@{
			sha1 = "fe2259f8796ff136dba4f8e05a45ebe529f06c08"
			sha512 = "37c0cbac4252044fe3cbdad8d1675926d2b8969e45aacc18ba6796f89ecf34ebd4d692bbce91b24046cf51055a2aca03fedbff793ead1f24379012cbd608037d"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/A8aBf1Xa/versions/mPNFFuBE/rotrBLOCKS%20V87%20%5B3D%20Foliage%5D%20128x%2026.2-1.13.zip")
		fileSize = 187966788
	},
	[ordered]@{
		path = "resourcepacks/Prime's HD Textures [32x].zip"
		hashes = [ordered]@{
			sha1 = "5401ad68f65e3e3e4ea0ebbc5b9136460ed529d5"
			sha512 = "7803399eee94c8fbff7b138682408459e9d0fad0c3aa7e4986fffef697cec0091aded12d4493ca7abfa1507933ae077108befb957d1a498b509980fc7e322941"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/PTSGmxET/versions/6imIUhAF/Prime%27s%20HD%20Textures%20%5B32x%5D.zip")
		fileSize = 22975488
	},
	[ordered]@{
		path = "resourcepacks/SPBR-21.zip"
		hashes = [ordered]@{
			sha1 = "b6adf388a22a1156d6751dbe68c56ba5c789d8c5"
			sha512 = "634722895afc8fd30a6975301c2ca6b0459792b396ed0808aee2ab6aba073fb21fd5ba7db83baee2bee96349730a3f5282f75f84dda18cd4914624ddac5d4f4d"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/aNcOVoD7/versions/S17DzSfS/SPBR-21.zip")
		fileSize = 25793506
	},
	[ordered]@{
		path = "resourcepacks/Optimum Realism R4.0.0 64x.zip"
		hashes = [ordered]@{
			sha1 = "54f36fda1d832f159611fadabd3cd1cbebc75273"
			sha512 = "2047992cedffb47c3b01f105511a6a6c6f3bf092c331451379a131baf2c018c967d3da6af990fbc33b9a9ab65e72aad0edf93cc7d51ebd07dc540d0e2d607c8a"
		}
		env = [ordered]@{ client = "required"; server = "unsupported" }
		downloads = @("https://cdn.modrinth.com/data/jbhXFk8s/versions/lqoCWZjS/Optimum%20Realism%20R4.0.0%2064x.zip")
		fileSize = 77944529
	}
)

function Set-MinecraftGraphicsDefaults {
	param(
		[Parameter(Mandatory)][string]$MinecraftRoot,
		[switch]$PreserveResourcePackSelection
	)

	$irisConfig = Join-Path $MinecraftRoot "config\iris.properties"
	New-Item -ItemType Directory -Path (Split-Path $irisConfig) -Force | Out-Null
	[IO.File]::WriteAllText(
		$irisConfig,
		"enableShaders=true`nshaderPack=$MinecraftShaderPack`n",
		[Text.UTF8Encoding]::new($false)
	)

	$shaderConfig = Join-Path $MinecraftRoot "shaderpacks\$MinecraftShaderPack.txt"
	New-Item -ItemType Directory -Path (Split-Path $shaderConfig) -Force | Out-Null
	[IO.File]::WriteAllText(
		$shaderConfig,
		"RP_MODE=3`nPOM=true`nPOM_QUALITY=128`nPOM_DISTANCE=32`n",
		[Text.UTF8Encoding]::new($false)
	)

	$optionsPath = Join-Path $MinecraftRoot "options.txt"
	$options = @(if (Test-Path -LiteralPath $optionsPath) {
		@(Get-Content -LiteralPath $optionsPath | Where-Object { $_ -notmatch "^(resourcePacks|incompatibleResourcePacks):" })
	} else {
		@()
	})
	$currentResourcePacks = if (Test-Path -LiteralPath $optionsPath) {
		Get-Content -LiteralPath $optionsPath | Where-Object { $_ -match "^resourcePacks:" } | Select-Object -First 1
	}
	$resourcePacks = @()
	if ($PreserveResourcePackSelection -and $currentResourcePacks) {
		$selectedPacks = ConvertFrom-Json -InputObject $currentResourcePacks.Substring("resourcePacks:".Length)
		foreach ($pack in $selectedPacks) {
			if (
				$pack -ne "file/$MinecraftAnimationResourcePack" -and
				$pack -ne "file/$MinecraftEmissiveResourcePack"
			) {
				$resourcePacks += [string]$pack
			}
		}
	} else {
		$resourcePacks = @("vanilla", "file/$MinecraftDefaultResourcePack")
	}
	$resourcePacks += "file/$MinecraftAnimationResourcePack"
	$resourcePacks += "file/$MinecraftEmissiveResourcePack"
	$options += "resourcePacks:$(ConvertTo-Json -InputObject @($resourcePacks) -Compress)"
	$options += "incompatibleResourcePacks:[]"
	[IO.File]::WriteAllText(
		$optionsPath,
		(($options -join "`n") + "`n"),
		[Text.UTF8Encoding]::new($false)
	)
}

function Sync-MinecraftGraphicsFiles {
	param(
		[Parameter(Mandatory)][string]$MinecraftRoot,
		[switch]$SkipSettings
	)

	# Retired managed mods must not survive from an older generation.
	$obsoletePatterns = @("visuality-*.jar")
	foreach ($obsoletePattern in $obsoletePatterns) {
		Get-ChildItem -LiteralPath (Join-Path $MinecraftRoot "mods") -Filter $obsoletePattern -File -ErrorAction SilentlyContinue |
			Remove-Item -Force
	}

	foreach ($file in $MinecraftGraphicsFiles) {
		$destination = Join-Path $MinecraftRoot ($file.path -replace "/", "\")
		$valid = (Test-Path -LiteralPath $destination -PathType Leaf) -and
			((Get-Item -LiteralPath $destination).Length -eq $file.fileSize) -and
			((Get-FileHash -LiteralPath $destination -Algorithm SHA512).Hash.ToLowerInvariant() -eq $file.hashes.sha512)
		if ($valid) {
			continue
		}

		New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
		$download = Join-Path $env:TEMP "minecraft-graphics-$([guid]::NewGuid().ToString('N')).download"
		try {
			Write-Host "Downloading $($file.path)..."
			Invoke-WebRequest -UseBasicParsing -Uri $file.downloads[0] -OutFile $download
			if ((Get-Item -LiteralPath $download).Length -ne $file.fileSize) {
				throw "Downloaded size mismatch for $($file.path)"
			}
			$actualHash = (Get-FileHash -LiteralPath $download -Algorithm SHA512).Hash.ToLowerInvariant()
			if ($actualHash -ne $file.hashes.sha512) {
				throw "Downloaded SHA-512 mismatch for $($file.path)"
			}
			Move-Item -LiteralPath $download -Destination $destination -Force
		} finally {
			Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
		}
	}
	if (-not $SkipSettings) {
		Set-MinecraftGraphicsDefaults -MinecraftRoot $MinecraftRoot -PreserveResourcePackSelection
	}
}

function Set-MinecraftInstanceMemory {
	param(
		[Parameter(Mandatory)][string]$InstanceRoot,
		[int]$MaximumMiB = 8192
	)

	$configPath = Join-Path $InstanceRoot "instance.cfg"
	if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
		throw "Prism instance configuration is missing: $configPath"
	}
	$config = @(
		Get-Content -LiteralPath $configPath |
			Where-Object { $_ -notmatch "^(MinMemAlloc|MaxMemAlloc|OverrideMemory|JvmArgs|OverrideJavaArgs)=" }
	)
	$config += "MinMemAlloc=1024"
	$config += "MaxMemAlloc=$MaximumMiB"
	$config += "OverrideMemory=true"
	$config += "JvmArgs=-XX:+UseZGC"
	$config += "OverrideJavaArgs=true"
	[IO.File]::WriteAllText(
		$configPath,
		(($config -join "`n") + "`n"),
		[Text.UTF8Encoding]::new($false)
	)
}
