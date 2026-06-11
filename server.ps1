$port = if ($env:PORT) { $env:PORT } else { 3501 }
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$port/")
$listener.Start()
Write-Host "Server running at http://localhost:$port"
while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response
    $path = $req.Url.LocalPath.TrimStart('/')

    # ---- Proxy HubSpot: /hs/* -> https://api.hubapi.com/* ----
    if ($path.StartsWith('hs/')) {
        try {
            $hsPath = $path.Substring(3)
            $hsUrl = "https://api.hubapi.com/$hsPath"
            if ($req.Url.Query) { $hsUrl += $req.Url.Query }
            $token = $req.Headers['X-HS-Token']
            if (-not $token) { throw "Token HubSpot ausente (header X-HS-Token)" }

            $web = [System.Net.HttpWebRequest]::Create($hsUrl)
            $web.Method = $req.HttpMethod
            $web.Headers.Add('Authorization', "Bearer $token")
            $web.ContentType = 'application/json'
            $web.Accept = 'application/json'

            if ($req.HttpMethod -in @('POST','PUT','PATCH')) {
                $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
                $body = $reader.ReadToEnd()
                $reader.Close()
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                $web.ContentLength = $bytes.Length
                $stream = $web.GetRequestStream()
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Close()
            }

            try {
                $hsRes = $web.GetResponse()
            } catch [System.Net.WebException] {
                $hsRes = $_.Exception.Response
                if (-not $hsRes) { throw }
            }
            $sr = New-Object System.IO.StreamReader($hsRes.GetResponseStream())
            $respBody = $sr.ReadToEnd()
            $sr.Close()
            $res.StatusCode = [int]$hsRes.StatusCode
            $outBytes = [System.Text.Encoding]::UTF8.GetBytes($respBody)
            $res.ContentType = 'application/json;charset=utf-8'
            $res.ContentLength64 = $outBytes.Length
            $res.OutputStream.Write($outBytes, 0, $outBytes.Length)
        } catch {
            $err = @{ error = $_.Exception.Message } | ConvertTo-Json
            $outBytes = [System.Text.Encoding]::UTF8.GetBytes($err)
            $res.StatusCode = 502
            $res.ContentType = 'application/json;charset=utf-8'
            $res.ContentLength64 = $outBytes.Length
            $res.OutputStream.Write($outBytes, 0, $outBytes.Length)
        }
        $res.OutputStream.Close()
        continue
    }

    if ($path -eq '' -or $path -eq '/') { $path = 'painel-meta-2026.html' }
    $file = Join-Path $root $path
    if (Test-Path $file) {
        $bytes = [System.IO.File]::ReadAllBytes($file)
        $ext = [System.IO.Path]::GetExtension($file).ToLower()
        $ct = switch ($ext) { '.html' {'text/html;charset=utf-8'} '.js' {'application/javascript'} '.css' {'text/css'} default {'application/octet-stream'} }
        $res.ContentType = $ct
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
        $res.StatusCode = 404
    }
    $res.OutputStream.Close()
}
