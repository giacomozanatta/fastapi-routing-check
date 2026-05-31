@rem
@rem Copyright 2015 the original author or authors.
@rem
@rem Licensed under the Apache License, Version 2.0 (the "License");
@rem you may not use this file except in compliance with the License.
@rem You may obtain a copy of the License at
@rem
@rem      https://www.apache.org/licenses/LICENSE-2.0
@rem
@rem Unless required by applicable law or agreed to in writing, software
@rem distributed under the License is distributed on an "AS IS" BASIS,
@rem WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
@rem See the License for the specific language governing permissions and
@rem limitations under the License.
@rem
@rem SPDX-License-Identifier: Apache-2.0
@rem

@if "%DEBUG%"=="" @echo off
@rem ##########################################################################
@rem
@rem  lisa-network startup script for Windows
@rem
@rem ##########################################################################

@rem Set local scope for the variables with windows NT shell
if "%OS%"=="Windows_NT" setlocal

set DIRNAME=%~dp0
if "%DIRNAME%"=="" set DIRNAME=.
@rem This is normally unused
set APP_BASE_NAME=%~n0
set APP_HOME=%DIRNAME%..

@rem Resolve any "." and ".." in APP_HOME to make it shorter.
for %%i in ("%APP_HOME%") do set APP_HOME=%%~fi

@rem Add default JVM options here. You can also use JAVA_OPTS and LISA_NETWORK_OPTS to pass JVM options to this script.
set DEFAULT_JVM_OPTS=

@rem Find java.exe
if defined JAVA_HOME goto findJavaFromJavaHome

set JAVA_EXE=java.exe
%JAVA_EXE% -version >NUL 2>&1
if %ERRORLEVEL% equ 0 goto execute

echo. 1>&2
echo ERROR: JAVA_HOME is not set and no 'java' command could be found in your PATH. 1>&2
echo. 1>&2
echo Please set the JAVA_HOME variable in your environment to match the 1>&2
echo location of your Java installation. 1>&2

goto fail

:findJavaFromJavaHome
set JAVA_HOME=%JAVA_HOME:"=%
set JAVA_EXE=%JAVA_HOME%/bin/java.exe

if exist "%JAVA_EXE%" goto execute

echo. 1>&2
echo ERROR: JAVA_HOME is set to an invalid directory: %JAVA_HOME% 1>&2
echo. 1>&2
echo Please set the JAVA_HOME variable in your environment to match the 1>&2
echo location of your Java installation. 1>&2

goto fail

:execute
@rem Setup the command line

set CLASSPATH=%APP_HOME%\lib\lisa-network-0.1.jar;%APP_HOME%\lib\pylisa-0.1.jar;%APP_HOME%\lib\jlisa-0.1.jar;%APP_HOME%\lib\lisa-analyses-0.1.jar;%APP_HOME%\lib\lisa-program-0.1.jar;%APP_HOME%\lib\lisa-sdk-0.1.jar;%APP_HOME%\lib\thymeleaf-3.0.15.RELEASE.jar;%APP_HOME%\lib\commons-text-1.10.0.jar;%APP_HOME%\lib\commons-lang3-3.14.0.jar;%APP_HOME%\lib\jaxb-runtime-4.0.5.jar;%APP_HOME%\lib\jaxb-core-4.0.5.jar;%APP_HOME%\lib\jaxb-impl-3.0.2.jar;%APP_HOME%\lib\jaxb-core-3.0.2.jar;%APP_HOME%\lib\jakarta.xml.bind-api-4.0.2.jar;%APP_HOME%\lib\pdfbox-3.0.5.jar;%APP_HOME%\lib\commons-io-2.8.0.jar;%APP_HOME%\lib\commons-collections4-4.4.jar;%APP_HOME%\lib\jackson-annotations-2.17.0.jar;%APP_HOME%\lib\jackson-core-2.17.0.jar;%APP_HOME%\lib\jackson-databind-2.17.0.jar;%APP_HOME%\lib\graphviz-java-0.18.1.jar;%APP_HOME%\lib\log4j-slf4j-impl-2.17.1.jar;%APP_HOME%\lib\log4j-core-2.20.0.jar;%APP_HOME%\lib\log4j-api-2.20.0.jar;%APP_HOME%\lib\reflections-0.9.12.jar;%APP_HOME%\lib\joda-time-2.10.14.jar;%APP_HOME%\lib\antlr4-4.8-1.jar;%APP_HOME%\lib\httpclient-4.5.14.jar;%APP_HOME%\lib\spring-web-6.1.6.jar;%APP_HOME%\lib\jdom2-2.0.5.jar;%APP_HOME%\lib\gson-2.8.7.jar;%APP_HOME%\lib\classgraph-4.8.175.jar;%APP_HOME%\lib\gs-core-2.0.jar;%APP_HOME%\lib\org.eclipse.jdt.core-3.41.0.jar;%APP_HOME%\lib\commons-cli-1.4.jar;%APP_HOME%\lib\ognl-3.1.26.jar;%APP_HOME%\lib\attoparser-2.0.5.RELEASE.jar;%APP_HOME%\lib\unbescape-1.1.6.RELEASE.jar;%APP_HOME%\lib\jcl-over-slf4j-1.7.30.jar;%APP_HOME%\lib\jul-to-slf4j-1.7.30.jar;%APP_HOME%\lib\slf4j-api-1.7.30.jar;%APP_HOME%\lib\angus-activation-2.0.2.jar;%APP_HOME%\lib\jakarta.activation-api-2.1.3.jar;%APP_HOME%\lib\fontbox-3.0.5.jar;%APP_HOME%\lib\pdfbox-io-3.0.5.jar;%APP_HOME%\lib\commons-logging-1.3.5.jar;%APP_HOME%\lib\viz.js-graphviz-java-2.1.3.jar;%APP_HOME%\lib\svgSalamander-1.1.3.jar;%APP_HOME%\lib\nashorn-promise-0.1.1.jar;%APP_HOME%\lib\commons-exec-1.3.jar;%APP_HOME%\lib\jsr305-3.0.2.jar;%APP_HOME%\lib\javassist-3.26.0-GA.jar;%APP_HOME%\lib\byte-buddy-1.14.9.jar;%APP_HOME%\lib\antlr4-runtime-4.8-1.jar;%APP_HOME%\lib\ST4-4.3.jar;%APP_HOME%\lib\antlr-runtime-3.5.2.jar;%APP_HOME%\lib\org.abego.treelayout.core-1.0.3.jar;%APP_HOME%\lib\javax.json-1.0.4.jar;%APP_HOME%\lib\icu4j-61.1.jar;%APP_HOME%\lib\httpcore-4.4.16.jar;%APP_HOME%\lib\commons-codec-1.11.jar;%APP_HOME%\lib\spring-beans-6.1.6.jar;%APP_HOME%\lib\spring-core-6.1.6.jar;%APP_HOME%\lib\micrometer-observation-1.12.5.jar;%APP_HOME%\lib\pherd-1.0.jar;%APP_HOME%\lib\mbox2-1.0.jar;%APP_HOME%\lib\org.eclipse.core.resources-3.22.100.jar;%APP_HOME%\lib\org.eclipse.core.filesystem-1.11.100.jar;%APP_HOME%\lib\org.eclipse.text-3.14.300.jar;%APP_HOME%\lib\org.eclipse.core.expressions-3.9.400.jar;%APP_HOME%\lib\org.eclipse.core.runtime-3.33.0.jar;%APP_HOME%\lib\ecj-3.41.0.jar;%APP_HOME%\lib\txw2-4.0.5.jar;%APP_HOME%\lib\istack-commons-runtime-4.1.2.jar;%APP_HOME%\lib\spring-jcl-6.1.6.jar;%APP_HOME%\lib\micrometer-commons-1.12.5.jar;%APP_HOME%\lib\jakarta.activation-2.0.1.jar;%APP_HOME%\lib\jna-platform-5.15.0.jar;%APP_HOME%\lib\jna-5.16.0.jar;%APP_HOME%\lib\org.eclipse.core.jobs-3.15.500.jar;%APP_HOME%\lib\org.eclipse.core.contenttype-3.9.600.jar;%APP_HOME%\lib\org.eclipse.equinox.app-1.7.300.jar;%APP_HOME%\lib\org.eclipse.equinox.registry-3.12.300.jar;%APP_HOME%\lib\org.eclipse.equinox.preferences-3.11.300.jar;%APP_HOME%\lib\org.eclipse.core.commands-3.12.300.jar;%APP_HOME%\lib\org.eclipse.equinox.common-3.20.0.jar;%APP_HOME%\lib\org.eclipse.osgi-3.23.0.jar;%APP_HOME%\lib\org.osgi.service.prefs-1.1.2.jar;%APP_HOME%\lib\osgi.annotation-8.0.1.jar


@rem Execute lisa-network
"%JAVA_EXE%" %DEFAULT_JVM_OPTS% %JAVA_OPTS% %LISA_NETWORK_OPTS%  -classpath "%CLASSPATH%" it.unive.lisa.Main %*

:end
@rem End local scope for the variables with windows NT shell
if %ERRORLEVEL% equ 0 goto mainEnd

:fail
rem Set variable LISA_NETWORK_EXIT_CONSOLE if you need the _script_ return code instead of
rem the _cmd.exe /c_ return code!
set EXIT_CODE=%ERRORLEVEL%
if %EXIT_CODE% equ 0 set EXIT_CODE=1
if not ""=="%LISA_NETWORK_EXIT_CONSOLE%" exit %EXIT_CODE%
exit /b %EXIT_CODE%

:mainEnd
if "%OS%"=="Windows_NT" endlocal

:omega
