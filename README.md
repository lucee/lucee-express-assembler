# lucee-express-assembler

Assembles a Lucee Express distribution from Maven Central instead of downloading the ~78 MB zip from the CDN.
It resolves `org.lucee:lucee-express:<version>` (a small POM plus a `template` zip, see
[LDEV-6524](https://luceeserver.atlassian.net/browse/LDEV-6524)), downloads the parts it lists (Apache Tomcat,
the Lucee jar, the javax API jars) with checksum verification, caches them in `~/.m2/repository` and builds the tree.

All assemblers apply the same layout rules (`lucee.express.layout=1`) and produce identical trees:

1. `tar.gz` dependency: extracted into the root, first path segment stripped, `webapps/` skipped
2. `jar` dependencies: `lib/ext/<artifactId>-<version>[-<classifier>].jar`
3. `lucee-express-<v>-template.zip`: extracted over the root last

| Tool | Needs | Usage |
| --- | --- | --- |
| `LuceeExpress.java` | JDK 11+ | `java LuceeExpress.java <version> <dir> [--repo URL]... [--cache DIR] [--read-cache DIR] [--offline] [--force]` |
| `lucee-express.sh` | sh, curl/wget, tar, unzip | `./lucee-express.sh <version> <dir>` (`LUCEE_EXPRESS_REPOS`, `LUCEE_EXPRESS_CACHE`, `LUCEE_EXPRESS_FORCE`) |
| `lucee-express.ps1` | PowerShell | `./lucee-express.ps1 <version> <dir>` |
| `maven/pom.xml` | Maven | `mvn -f maven/pom.xml package -Dlucee.version=<version>` |

A checksum mismatch is an error and callers must not fall back to another source. A missing artifact is reported
separately so that callers may fall back (for example to the CDN zip).

## Tests

`sh tests/fake-repo-test.sh` builds a fake `file:` repository and checks layout, cache reuse, not-found and checksum
mismatch for the Java and shell assemblers and that their trees are identical. CI runs this on Linux and macOS and
assembles the versions in `tests/published-versions.txt` on Linux, macOS and Windows.

## Status

Not yet implemented: `-SNAPSHOT` resolution through `maven-metadata.xml`, proxy settings, Windows test coverage of the
fake-repo test for the PowerShell script.
