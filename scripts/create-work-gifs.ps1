param(
  [Parameter(Mandatory = $true)]
  [string]$InputPath,

  [Parameter(Mandatory = $true)]
  [string]$OutputPath,

  [string]$PosterPath,

  [int]$Width = 720,
  [int]$Height = 480,
  [int]$FrameCount = 18,
  [int]$FrameDelay = 8,
  [double]$PanX = 9,
  [double]$PanY = 5
)

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$resolvedInput = (Resolve-Path -LiteralPath $InputPath).Path
$resolvedOutput = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = [System.IO.Path]::GetDirectoryName($resolvedOutput)

if (-not [System.IO.Directory]::Exists($outputDirectory)) {
  [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}

$source = New-Object System.Windows.Media.Imaging.BitmapImage
$source.BeginInit()
$source.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
$source.UriSource = New-Object System.Uri($resolvedInput)
$source.EndInit()
$source.Freeze()

$encoder = New-Object System.Windows.Media.Imaging.GifBitmapEncoder

for ($index = 0; $index -lt $FrameCount; $index++) {
  $phase = (2 * [Math]::PI * $index) / $FrameCount
  $scale = 1.045 + (0.018 * [Math]::Sin($phase - ([Math]::PI / 2)))
  $renderWidth = $Width * $scale
  $renderHeight = $Height * $scale
  $left = (($Width - $renderWidth) / 2) + ($PanX * [Math]::Sin($phase))
  $top = (($Height - $renderHeight) / 2) + ($PanY * [Math]::Cos($phase))

  $visual = New-Object System.Windows.Media.DrawingVisual
  $drawing = $visual.RenderOpen()
  $drawing.DrawImage(
    $source,
    (New-Object System.Windows.Rect($left, $top, $renderWidth, $renderHeight))
  )
  $drawing.Close()

  $render = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
    $Width,
    $Height,
    96,
    96,
    [System.Windows.Media.PixelFormats]::Pbgra32
  )
  $render.Render($visual)
  $render.Freeze()

  if ($index -eq 0 -and -not [string]::IsNullOrWhiteSpace($PosterPath)) {
    $resolvedPoster = [System.IO.Path]::GetFullPath($PosterPath)
    $posterDirectory = [System.IO.Path]::GetDirectoryName($resolvedPoster)
    if (-not [System.IO.Directory]::Exists($posterDirectory)) {
      [System.IO.Directory]::CreateDirectory($posterDirectory) | Out-Null
    }

    $posterEncoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $posterEncoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($render))
    $posterStream = [System.IO.File]::Open(
      $resolvedPoster,
      [System.IO.FileMode]::Create,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::None
    )
    try {
      $posterEncoder.Save($posterStream)
    }
    finally {
      $posterStream.Dispose()
    }
  }

  $metadata = New-Object System.Windows.Media.Imaging.BitmapMetadata('gif')
  $metadata.SetQuery('/grctlext/Delay', [UInt16]$FrameDelay)
  $metadata.SetQuery('/grctlext/Disposal', [Byte]2)

  if ($index -eq 0) {
    $metadata.SetQuery('/appext/application', [System.Text.Encoding]::ASCII.GetBytes('NETSCAPE2.0'))
    $metadata.SetQuery('/appext/data', [Byte[]](3, 1, 0, 0))
  }

  $frame = [System.Windows.Media.Imaging.BitmapFrame]::Create($render, $null, $metadata, $null)
  $encoder.Frames.Add($frame)
}

$stream = [System.IO.File]::Open(
  $resolvedOutput,
  [System.IO.FileMode]::Create,
  [System.IO.FileAccess]::Write,
  [System.IO.FileShare]::None
)

try {
  $encoder.Save($stream)
}
finally {
  $stream.Dispose()
}

# WPF writes multi-frame GIFs, but it drops the frame delay and looping
# metadata. Patch those two standard GIF89a blocks after encoding so the
# resulting files loop consistently in browsers.
$gifBytes = [System.IO.File]::ReadAllBytes($resolvedOutput)
$packedFields = $gifBytes[10]
$globalColorTableSize = 0
if (($packedFields -band 0x80) -ne 0) {
  $globalColorTableSize = 3 * [Math]::Pow(2, (($packedFields -band 0x07) + 1))
}

$loopInsertOffset = 13 + [int]$globalColorTableSize
$delayLow = [Byte]($FrameDelay -band 0xFF)
$delayHigh = [Byte](($FrameDelay -shr 8) -band 0xFF)
$cursor = $loopInsertOffset

while ($cursor -lt $gifBytes.Length) {
  $marker = $gifBytes[$cursor]

  if ($marker -eq 0x21) {
    $extensionLabel = $gifBytes[$cursor + 1]
    if ($extensionLabel -eq 0xF9) {
      $gifBytes[$cursor + 4] = $delayLow
      $gifBytes[$cursor + 5] = $delayHigh
      $cursor += 8
      continue
    }

    $cursor += 2
    while ($cursor -lt $gifBytes.Length) {
      $blockSize = $gifBytes[$cursor]
      $cursor++
      if ($blockSize -eq 0) { break }
      $cursor += $blockSize
    }
    continue
  }

  if ($marker -eq 0x2C) {
    $localPackedFields = $gifBytes[$cursor + 9]
    $cursor += 10
    if (($localPackedFields -band 0x80) -ne 0) {
      $cursor += 3 * [Math]::Pow(2, (($localPackedFields -band 0x07) + 1))
    }

    $cursor++
    while ($cursor -lt $gifBytes.Length) {
      $blockSize = $gifBytes[$cursor]
      $cursor++
      if ($blockSize -eq 0) { break }
      $cursor += $blockSize
    }
    continue
  }

  if ($marker -eq 0x3B) { break }
  throw "Unexpected GIF block marker 0x$($marker.ToString('X2')) at offset $cursor."
}

$loopExtension = [Byte[]](
  0x21, 0xFF, 0x0B,
  0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45, 0x32, 0x2E, 0x30,
  0x03, 0x01, 0x00, 0x00, 0x00
)
$loopingGif = New-Object Byte[] ($gifBytes.Length + $loopExtension.Length)
[System.Buffer]::BlockCopy($gifBytes, 0, $loopingGif, 0, $loopInsertOffset)
[System.Buffer]::BlockCopy($loopExtension, 0, $loopingGif, $loopInsertOffset, $loopExtension.Length)
[System.Buffer]::BlockCopy(
  $gifBytes,
  $loopInsertOffset,
  $loopingGif,
  ($loopInsertOffset + $loopExtension.Length),
  ($gifBytes.Length - $loopInsertOffset)
)
[System.IO.File]::WriteAllBytes($resolvedOutput, $loopingGif)

Write-Output $resolvedOutput
