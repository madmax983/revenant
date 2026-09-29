//! Defect and report types. The JSON shape is a stable contract.

use serde::{Deserialize, Serialize};

/// Report format version. Increase it only for a breaking JSON change.
pub const REPORT_VERSION: u32 = 1;

/// How serious a defect is. The order is `Low < Medium < High`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum Severity {
    /// Information. The scan is not complete.
    Low,
    /// Possible hazard. Examine it.
    Medium,
    /// Replay-unsafe. The default gate fails.
    High,
}

/// Stable defect code.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum DefectCode {
    /// A step class calls an API that can give a different value on replay.
    NonDeterministicSource,
    /// `getSteps()` names a class that is not in the scanned source.
    StepSourceNotFound,
    /// The lexer cannot read the file. The file is not scanned.
    SourceUnreadable,
}

/// Stable hazard rule of a `NON_DETERMINISTIC_SOURCE` defect.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum Rule {
    /// `Datetime.now()`, `System.now()`, `System.today()`, `Date.today()`,
    /// `System.currentTimeMillis()`.
    ClockRead,
    /// `Math.random()`, `Crypto.getRandom*()`, `Crypto.generateAesKey()`,
    /// `UUID.randomUUID()`.
    RandomValue,
    /// `UserInfo.*()`.
    UserContext,
    /// `System.enqueueJob()`, `Database.executeBatch()`, `System.schedule()`,
    /// `System.scheduleBatch()`.
    AsyncEnqueue,
    /// Inline SOQL or SOSL, `Database.query*()`, `Database.countQuery()`,
    /// `Database.getQueryLocator()`, `Search.query()`.
    SoqlRead,
}

impl Rule {
    /// The severity of the rule.
    #[must_use]
    pub const fn severity(self) -> Severity {
        match self {
            Self::SoqlRead => Severity::Medium,
            Self::ClockRead | Self::RandomValue | Self::UserContext | Self::AsyncEnqueue => {
                Severity::High
            }
        }
    }

    /// One-line remedy. It points to the capture-once API.
    #[must_use]
    pub const fn remedy(self) -> &'static str {
        match self {
            Self::ClockRead | Self::RandomValue | Self::UserContext => {
                "Put the call in a CaptureProducer and read the value with ctx.captures().once(key, producer)."
            }
            Self::AsyncEnqueue => {
                "Put the call in a CaptureProducer and use ctx.captures().once(key, producer), so a replay does not start the job again."
            }
            Self::SoqlRead => {
                "If other processes change the rows, keep the result with ctx.captures().once(key, producer), or send the value as a signal."
            }
        }
    }
}

/// A 1-based source position. The column counts `char`s.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct Position {
    /// 1-based line.
    pub line: u32,
    /// 1-based column, in `char`s.
    pub column: u32,
}

/// One finding.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Defect {
    /// Stable defect code.
    pub code: DefectCode,
    /// Hazard rule. Only for `NON_DETERMINISTIC_SOURCE`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rule: Option<Rule>,
    /// Severity.
    pub severity: Severity,
    /// Qualified class name (`Outer.Inner`). Empty when the file is unreadable.
    pub class_name: String,
    /// File path, as given.
    pub file: String,
    /// Position of the finding.
    #[serde(flatten)]
    pub position: Position,
    /// The API call or the step name, as written in the source.
    pub api: String,
    /// What is wrong.
    pub message: String,
    /// What to do.
    pub remedy: String,
}

/// The result of one lint run.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    /// Format version. See [`REPORT_VERSION`].
    pub version: u32,
    /// Number of `.cls` files given, test files included.
    pub files_scanned: usize,
    /// Number of step classes scanned.
    pub step_classes_scanned: usize,
    /// Number of findings that a suppression comment removed.
    pub suppressed: usize,
    /// All findings, sorted by file, line, column, code and rule.
    pub defects: Vec<Defect>,
}

impl Report {
    /// True when a defect has this severity or a higher one.
    #[must_use]
    pub fn has_at_least(&self, severity: Severity) -> bool {
        self.defects.iter().any(|d| d.severity >= severity)
    }
}
