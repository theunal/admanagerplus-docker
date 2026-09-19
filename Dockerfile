FROM mcr.microsoft.com/windows/servercore:ltsc2025

LABEL maintainer="unal"
LABEL description="ManageEngine ADManager Plus"

SHELL ["powershell", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';"]

WORKDIR C:/install
COPY ManageEngine_ADManager_Plus_64_GA.exe .
COPY setup.iss C:/ADManager/setup.iss
COPY entrypoint.ps1 C:/entrypoint.ps1

EXPOSE 8080 8443

ENTRYPOINT ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\entrypoint.ps1"]