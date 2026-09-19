# AdManager Docker Kullanimi

## Konteyneri Baslatma

```powershell
docker run --name admanager -it -p 8080:8080 326229903/admanager
```

## DNS Ayarlarini Yapilandirma

Konteynerin PowerShell oturumuna baglanin:

```powershell
docker exec -it admanager powershell
```

DNS sunucularini ayarlayin ve alan adini dogrulayin:

```powershell
Set-DnsClientServerAddress -InterfaceIndex 4 -ServerAddresses <DC_IP>,192.168.1.1
Resolve-DnsName <domain_adi>
```

## DNS Ayarlariyla Baslatma

DNS ayarlarini konteyner baslatilirken vermek icin:

```powershell
docker run --name admanager -it -p 8080:8080 --dns <DC_IP> --dns 192.168.1.1 --dns-search <domain_adi> 326229903/admanager
```

docker run --name admanager -it -p 8080:8080 --dns <DC_IP> --dns 192.168.1.1 --dns-search <domain_adi> 326229903/admanager