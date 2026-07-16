using System;
using System.Linq;
using System.Windows.Media;
using ToolkitGUI.Services;

namespace ToolkitGUI.Models
{
  /// <summary>One row in the workflow execution Structured Results panel.</summary>
  public sealed class StructuredResultItemViewModel
  {
    private static readonly string[] CstFindingTypes =
    {
      "Malware", "Virus", "PUP", "PUM", "Suspicious"
    };

    private const string StartupRiskBandSuffix = " · Risk band: ";

    public string Name { get; init; } = string.Empty;
    public string Severity { get; init; } = string.Empty;
    public string Classification { get; init; } = string.Empty;
    public bool IsStartupReviewItem { get; init; }
    public string ReviewReason { get; init; } = string.Empty;
    public string StartupLocation { get; init; } = string.Empty;
    public string RiskBand { get; init; } = string.Empty;
    public string RiskBandNote { get; init; } =
      "Trust score for the target binary/path. An entry can be Safe here and still be flagged when audit rules fire (for example RunOnce or unsigned).";
    public string EntryPath { get; init; } = string.Empty;
    public string EntryLocation { get; init; } = string.Empty;
    public string DetailNotes { get; init; } = string.Empty;
    public string StatusLabelText { get; init; } = string.Empty;
    public Brush StatusLabelBrush { get; init; } = Brushes.SteelBlue;
    public bool IsCompactStartupVerified { get; init; }
    public bool ShowCompactStartupRow => IsCompactStartupVerified;
    public bool ShowRichEntry =>
      !IsCompactStartupVerified
      && (!string.IsNullOrWhiteSpace(EntryLocation) || !string.IsNullOrWhiteSpace(DetailNotes));
    public bool ShowCompactFilePath =>
      !IsStartupReviewItem
      && !IsCompactStartupVerified
      && !string.IsNullOrWhiteSpace(EntryPath)
      && !ShowRichEntry;
    public bool ShowStatusLabel => !IsCompactStartupVerified && !string.IsNullOrWhiteSpace(StatusLabelText);
    public bool ShowEntryLocation => !string.IsNullOrWhiteSpace(EntryLocation);
    public bool ShowEntryPath => !string.IsNullOrWhiteSpace(EntryPath);
    public bool ShowDetailNotes => !string.IsNullOrWhiteSpace(DetailNotes);
    public Brush SeverityBrush { get; init; } = Brushes.SteelBlue;
    public Brush ClassificationBrush { get; init; } = Brushes.SteelBlue;
    public Brush RiskBandBrush { get; init; } = Brushes.SteelBlue;
    public bool ShowSeverity => !IsStartupReviewItem && !IsCompactStartupVerified && !string.IsNullOrWhiteSpace(Severity);
    public bool ShowClassification => !IsStartupReviewItem && !IsCompactStartupVerified && !string.IsNullOrWhiteSpace(Classification);
    public bool ShowStartupReviewDetails => IsStartupReviewItem && !IsCompactStartupVerified;
    public bool ShowRiskBand =>
      !string.IsNullOrWhiteSpace(RiskBand)
      && (IsStartupReviewItem || IsCompactStartupVerified);
    public bool ShowStartupTargetPath =>
      IsStartupReviewItem && !IsCompactStartupVerified && !string.IsNullOrWhiteSpace(EntryPath);
    public string CompactStartupSummary =>
      string.IsNullOrWhiteSpace(StartupLocation) ? Name : $"{Name} · {StartupLocation}";

    public string DedupKey =>
      $"{Name}|{Severity}|{Classification}|{EntryPath}".ToLowerInvariant();

    /// <summary>Rebuilds a row on the current thread (must be the UI thread for WPF brushes).</summary>
    public static StructuredResultItemViewModel Rebuild(string name, string severity, string classification)
    {
      if (string.IsNullOrWhiteSpace(severity) && string.IsNullOrWhiteSpace(classification))
      {
        return CreatePlain(name);
      }

      if (TryParseStartupClassification(classification, out var location, out var riskBand))
      {
        var reasons = IsStartupRiskBand(severity) ? null : severity;
        return FromStartupAudit(name, location, riskBand, reasons);
      }

      if (IsStartupRiskBand(severity))
      {
        return FromStartupAudit(name, classification, severity.Trim(), null);
      }

      return FromCstFinding(name, severity, classification, null, null, null);
    }

    internal static StructuredResultItemViewModel FromFormattedItem(FormattedResultItem item)
    {
      if (string.IsNullOrWhiteSpace(item.Title))
      {
        return new StructuredResultItemViewModel();
      }

      if (item.Status == FormattedItemStatus.Review)
      {
        return FromStartupAudit(
          item.Title,
          item.Location ?? string.Empty,
          ExtractRiskBand(item.Notes),
          ExtractReviewReason(item.Notes),
          item.Path);
      }

      if (item.Compact && item.Status == FormattedItemStatus.Ok)
      {
        return FromStartupVerifiedCompact(item);
      }

      var subtitle = item.Subtitle ?? string.Empty;
      if (!string.IsNullOrWhiteSpace(item.Notes) && string.IsNullOrWhiteSpace(subtitle))
      {
        subtitle = item.Notes;
      }
      else if (!string.IsNullOrWhiteSpace(item.Notes))
      {
        subtitle = $"{subtitle} · {item.Notes}";
      }

      return new StructuredResultItemViewModel
      {
        Name = item.Title,
        StatusLabelText = item.StatusLabel,
        StatusLabelBrush = GetFormattedStatusBrush(item.Status),
        EntryLocation = item.Location ?? string.Empty,
        EntryPath = item.Path ?? string.Empty,
        DetailNotes = subtitle,
        Severity = item.Status switch
        {
          FormattedItemStatus.Fail => "Fail",
          FormattedItemStatus.Warning => "Warning",
          FormattedItemStatus.Review => "Review",
          FormattedItemStatus.Ok => "OK",
          _ => string.Empty
        },
        Classification = subtitle,
        SeverityBrush = GetFormattedStatusBrush(item.Status),
        ClassificationBrush = new SolidColorBrush(Color.FromRgb(0x37, 0x47, 0x5F))
      };
    }

    private static StructuredResultItemViewModel FromStartupVerifiedCompact(FormattedResultItem item)
    {
      var band = ExtractRiskBand(item.Notes) ?? "Safe";
      var loc = string.IsNullOrWhiteSpace(item.Location) ? "Unknown location" : item.Location.Trim();

      return new StructuredResultItemViewModel
      {
        Name = NormalizeName(item.Title),
        IsCompactStartupVerified = true,
        StartupLocation = loc,
        RiskBand = band,
        EntryPath = item.Path ?? string.Empty,
        StatusLabelText = string.IsNullOrWhiteSpace(item.StatusLabel) ? "Verified" : item.StatusLabel,
        StatusLabelBrush = GetFormattedStatusBrush(FormattedItemStatus.Ok),
        RiskBandBrush = GetStartupRiskBrush(band),
        Severity = "OK",
        Classification = $"{loc}{StartupRiskBandSuffix}{band}",
        SeverityBrush = GetFormattedStatusBrush(FormattedItemStatus.Ok),
        ClassificationBrush = new SolidColorBrush(Color.FromRgb(0x37, 0x47, 0x5F))
      };
    }

    private static string? ExtractRiskBand(string? notes)
    {
      if (string.IsNullOrWhiteSpace(notes))
      {
        return "Safe";
      }

      const string prefix = "Trust band: ";
      foreach (var part in notes.Split('·', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
      {
        if (part.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        {
          return part[prefix.Length..].Trim();
        }
      }

      return "Safe";
    }

    private static string? ExtractReviewReason(string? notes)
    {
      if (string.IsNullOrWhiteSpace(notes))
      {
        return null;
      }

      const string prefix = "Trust band: ";
      var parts = notes.Split('·', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
      var reasons = parts.Where(p => !p.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)).ToList();
      return reasons.Count == 0 ? null : string.Join(" · ", reasons);
    }

    private static Brush GetFormattedStatusBrush(FormattedItemStatus status)
    {
      return status switch
      {
        FormattedItemStatus.Ok => new SolidColorBrush(Color.FromRgb(0x2E, 0x7D, 0x32)),
        FormattedItemStatus.Review => new SolidColorBrush(Color.FromRgb(0x92, 0x68, 0x00)),
        FormattedItemStatus.Warning => new SolidColorBrush(Color.FromRgb(0xD2, 0x99, 0x22)),
        FormattedItemStatus.Fail => new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
        FormattedItemStatus.Info => new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4)),
        _ => new SolidColorBrush(Color.FromRgb(0x5A, 0x6B, 0x80))
      };
    }

    public static StructuredResultItemViewModel CreatePlain(string? itemName)
    {
      var name = NormalizeName(itemName);
      if (string.IsNullOrWhiteSpace(name))
      {
        return new StructuredResultItemViewModel();
      }

      return new StructuredResultItemViewModel
      {
        Name = name,
        Severity = string.Empty,
        Classification = string.Empty,
        SeverityBrush = Brushes.Transparent,
        ClassificationBrush = Brushes.Transparent
      };
    }

    public static StructuredResultItemViewModel FromEventLogEntry(
      string? logName,
      string? source,
      int eventId,
      string? message,
      int occurrenceCount)
    {
      var log = string.IsNullOrWhiteSpace(logName) ? "Event" : logName.Trim();
      var src = string.IsNullOrWhiteSpace(source) ? "Unknown source" : source.Trim();
      var displayName = $"{log} · {src}";
      if (eventId > 0)
      {
        displayName += $" ({eventId})";
      }

      var detail = string.IsNullOrWhiteSpace(message) ? "No message text" : message.Trim();
      if (occurrenceCount > 1)
      {
        detail += $" — {occurrenceCount} occurrences in last 24h";
      }

      return new StructuredResultItemViewModel
      {
        Name = displayName,
        Severity = "Error",
        Classification = detail,
        SeverityBrush = new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
        ClassificationBrush = new SolidColorBrush(Color.FromRgb(0x37, 0x47, 0x5F))
      };
    }

    public static StructuredResultItemViewModel FromDiagnosticFinding(
      string? stepName,
      string? detail,
      string? status)
    {
      var label = ResolveDiagnosticLabel(stepName);
      if (string.IsNullOrWhiteSpace(label))
      {
        return new StructuredResultItemViewModel();
      }

      var detailText = string.IsNullOrWhiteSpace(detail) ? "No detail" : detail.Trim();
      var normalizedStatus = (status ?? string.Empty).Trim();
      var severity = normalizedStatus.Equals("Fail", StringComparison.OrdinalIgnoreCase)
        ? "Fail"
        : normalizedStatus.Equals("Warn", StringComparison.OrdinalIgnoreCase)
          ? "Warning"
          : string.Empty;

      return new StructuredResultItemViewModel
      {
        Name = label,
        Severity = severity,
        Classification = detailText,
        SeverityBrush = GetDiagnosticStatusBrush(normalizedStatus),
        ClassificationBrush = new SolidColorBrush(Color.FromRgb(0x37, 0x47, 0x5F))
      };
    }

    public static bool IsDiagnosticIssueStatus(string? status)
    {
      if (string.IsNullOrWhiteSpace(status))
      {
        return false;
      }

      return status.Equals("Warn", StringComparison.OrdinalIgnoreCase)
        || status.Equals("Fail", StringComparison.OrdinalIgnoreCase);
    }

    public static StructuredResultItemViewModel FromStartupAudit(
      string? name,
      string? location,
      string? riskBand,
      string? reasons = null,
      string? path = null)
    {
      var normalizedName = NormalizeName(name);
      if (string.IsNullOrWhiteSpace(normalizedName))
      {
        return new StructuredResultItemViewModel();
      }

      var band = string.IsNullOrWhiteSpace(riskBand) ? "Caution" : riskBand.Trim();
      var loc = string.IsNullOrWhiteSpace(location) ? "Unknown location" : location.Trim();
      var reviewReason = FormatStartupReviewSeverity(reasons);
      var entryPath = string.IsNullOrWhiteSpace(path) ? string.Empty : path.Trim();

      return new StructuredResultItemViewModel
      {
        Name = normalizedName,
        IsStartupReviewItem = true,
        ReviewReason = reviewReason,
        StartupLocation = loc,
        RiskBand = band,
        EntryPath = entryPath,
        StatusLabelText = "Needs review",
        StatusLabelBrush = GetFormattedStatusBrush(FormattedItemStatus.Review),
        Severity = string.Empty,
        Classification = $"{loc}{StartupRiskBandSuffix}{band}",
        SeverityBrush = GetStartupReviewSeverityBrush(reasons, band),
        RiskBandBrush = GetStartupRiskBrush(band),
        ClassificationBrush = new SolidColorBrush(Color.FromRgb(0x37, 0x47, 0x5F))
      };
    }

    public static StructuredResultItemViewModel FromCstFinding(
      string? name,
      string? severity,
      string? findingType,
      string? detector = null,
      string? evidence = null,
      string? location = null)
    {
      var normalizedName = NormalizeName(name);
      if (string.IsNullOrWhiteSpace(normalizedName))
      {
        return new StructuredResultItemViewModel();
      }

      var normalizedSeverity = NormalizeSeverity(severity);
      var classification = ResolveClassificationLabel(findingType, detector, evidence);
      var entryPath = string.IsNullOrWhiteSpace(location) ? string.Empty : location.Trim();

      return new StructuredResultItemViewModel
      {
        Name = normalizedName,
        EntryPath = entryPath,
        Severity = normalizedSeverity,
        Classification = classification,
        SeverityBrush = GetSeverityBrush(normalizedSeverity),
        ClassificationBrush = GetClassificationBrush(classification)
      };
    }

    public static bool IsCstFindingTypeToken(string? token)
    {
      if (string.IsNullOrWhiteSpace(token))
      {
        return false;
      }

      foreach (var known in CstFindingTypes)
      {
        if (string.Equals(known, token.Trim(), StringComparison.OrdinalIgnoreCase))
        {
          return true;
        }
      }

      return false;
    }

    private static string NormalizeName(string? itemName)
    {
      if (string.IsNullOrWhiteSpace(itemName))
      {
        return string.Empty;
      }

      return System.Text.RegularExpressions.Regex.Replace(itemName.Trim(), @"\s{2,}", " ");
    }

    private static string NormalizeSeverity(string? severity)
    {
      if (string.IsNullOrWhiteSpace(severity))
      {
        return string.Empty;
      }

      var trimmed = severity.Trim();
      if (trimmed.Length == 0)
      {
        return string.Empty;
      }

      return char.ToUpper(trimmed[0]) + trimmed[1..].ToLowerInvariant();
    }

    private static string ResolveClassificationLabel(string? findingType, string? detector, string? evidence)
    {
      var evidenceLower = (evidence ?? string.Empty).ToLowerInvariant();
      var detectorLower = (detector ?? string.Empty).ToLowerInvariant();

      if (evidenceLower.Contains("rootkit", StringComparison.Ordinal))
      {
        return "Rootkit";
      }

      if (evidenceLower.Contains("spyware", StringComparison.Ordinal)
          || evidenceLower.Contains("keylogger", StringComparison.Ordinal))
      {
        return "Spyware";
      }

      if (evidenceLower.Contains("ransom", StringComparison.Ordinal)
          || evidenceLower.Contains("cryptolocker", StringComparison.Ordinal))
      {
        return "Ransomware";
      }

      if (evidenceLower.Contains("stealer", StringComparison.Ordinal)
          || evidenceLower.Contains("infostealer", StringComparison.Ordinal))
      {
        return "Infostealer";
      }

      if (evidenceLower.Contains("trojan", StringComparison.Ordinal))
      {
        return "Trojan";
      }

      if (evidenceLower.Contains("worm", StringComparison.Ordinal))
      {
        return "Worm";
      }

      if (evidenceLower.Contains("boot sector", StringComparison.Ordinal)
          || evidenceLower.Contains("mbr", StringComparison.Ordinal)
          || evidenceLower.Contains("vbr", StringComparison.Ordinal)
          || detectorLower.Contains("mbrvbr")
          || detectorLower.Contains("bootfileintegrity")
          || detectorLower.Contains("bcdinspector")
          || detectorLower.Contains("gptstructure"))
      {
        return "Boot threat";
      }

      if (string.IsNullOrWhiteSpace(findingType))
      {
        return "Suspicious";
      }

      return findingType.Trim() switch
      {
        var t when t.Equals("Malware", StringComparison.OrdinalIgnoreCase) => "Malware",
        var t when t.Equals("Virus", StringComparison.OrdinalIgnoreCase) => "Virus",
        var t when t.Equals("PUP", StringComparison.OrdinalIgnoreCase) => "PUP",
        var t when t.Equals("PUM", StringComparison.OrdinalIgnoreCase) => "PUM",
        var t when t.Equals("Suspicious", StringComparison.OrdinalIgnoreCase) => "Suspicious",
        _ => findingType.Trim()
      };
    }

    private static Brush GetSeverityBrush(string severity)
    {
      return severity.ToUpperInvariant() switch
      {
        "CRITICAL" => new SolidColorBrush(Color.FromRgb(0xA9, 0x1F, 0x16)),
        "HIGH" => new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
        "MEDIUM" => new SolidColorBrush(Color.FromRgb(0xD2, 0x99, 0x22)),
        "LOW" => new SolidColorBrush(Color.FromRgb(0x5A, 0x7D, 0x1A)),
        _ => new SolidColorBrush(Color.FromRgb(0x60, 0x67, 0x6E))
      };
    }

    private static string ResolveDiagnosticLabel(string? stepName)
    {
      if (string.IsNullOrWhiteSpace(stepName))
      {
        return string.Empty;
      }

      return stepName.Trim() switch
      {
        "EnvironmentDetection" => "Environment",
        "OSVersion" => "OS Version",
        "CPULoad" => "CPU Load",
        "RAM" => "Memory",
        "DiskSMART" => "Disk SMART",
        "DiskSpace" => "Disk Space",
        "Activation" => "Windows Activation",
        "EventLogErrors" => "Event Log Errors",
        "SystemInfo" => "System Info",
        "DriverAudit" => "Driver Audit",
        "CPUTemperature" => "CPU Temperature",
        "MemoryDiagnosticHistory" => "Memory Diagnostic",
        "WindowsUpdateService" => "Windows Update",
        "NetworkAdapters" => "Network Adapters",
        "GPUInfo" => "GPU",
        "CriticalEvents" => "Critical Events",
        _ => NormalizeName(SplitPascalCase(stepName))
      };
    }

    private static string SplitPascalCase(string value)
    {
      if (string.IsNullOrWhiteSpace(value))
      {
        return string.Empty;
      }

      return System.Text.RegularExpressions.Regex.Replace(value.Trim(), "([a-z])([A-Z])", "$1 $2");
    }

    private static Brush GetDiagnosticStatusBrush(string status)
    {
      return status.ToUpperInvariant() switch
      {
        "FAIL" => new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
        "WARN" => new SolidColorBrush(Color.FromRgb(0x92, 0x68, 0x00)),
        _ => new SolidColorBrush(Color.FromRgb(0x60, 0x67, 0x6E))
      };
    }

    private static bool IsStartupRiskBand(string? value)
    {
      if (string.IsNullOrWhiteSpace(value))
      {
        return false;
      }

      var band = value.Trim();
      return band.Equals("Warning", StringComparison.OrdinalIgnoreCase)
        || band.Equals("Caution", StringComparison.OrdinalIgnoreCase)
        || band.Equals("Safe", StringComparison.OrdinalIgnoreCase);
    }

    private static bool TryParseStartupClassification(
      string? classification,
      out string location,
      out string riskBand)
    {
      location = string.Empty;
      riskBand = string.Empty;
      if (string.IsNullOrWhiteSpace(classification))
      {
        return false;
      }

      var idx = classification.LastIndexOf(StartupRiskBandSuffix, StringComparison.Ordinal);
      if (idx < 0)
      {
        return false;
      }

      location = classification[..idx].Trim();
      riskBand = classification[(idx + StartupRiskBandSuffix.Length)..].Trim();
      return !string.IsNullOrWhiteSpace(location) && !string.IsNullOrWhiteSpace(riskBand);
    }

    private static string FormatStartupReviewSeverity(string? reasons)
    {
      if (!string.IsNullOrWhiteSpace(reasons))
      {
        return reasons.Trim();
      }

      return "Needs review";
    }

    private static Brush GetStartupReviewSeverityBrush(string? reasons, string riskBand)
    {
      if (!string.IsNullOrWhiteSpace(reasons))
      {
        return new SolidColorBrush(Color.FromRgb(0x92, 0x68, 0x00));
      }

      return GetStartupRiskBrush(riskBand);
    }

    private static Brush GetStartupRiskBrush(string riskBand)
    {
      return riskBand.Trim().ToUpperInvariant() switch
      {
        "WARNING" => new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
        "CAUTION" => new SolidColorBrush(Color.FromRgb(0xD2, 0x99, 0x22)),
        "SAFE" => new SolidColorBrush(Color.FromRgb(0x2E, 0x7D, 0x32)),
        _ => new SolidColorBrush(Color.FromRgb(0x92, 0x68, 0x00))
      };
    }

    private static Brush GetClassificationBrush(string classification)
    {
      return classification.ToUpperInvariant() switch
      {
        "MALWARE" or "VIRUS" or "TROJAN" or "RANSOMWARE" or "ROOTKIT" or "WORM" or "INFOSTEALER" =>
          new SolidColorBrush(Color.FromRgb(0xC4, 0x2B, 0x1C)),
        "SPYWARE" => new SolidColorBrush(Color.FromRgb(0x8E, 0x24, 0xAA)),
        "PUP" => new SolidColorBrush(Color.FromRgb(0xD2, 0x99, 0x22)),
        "PUM" => new SolidColorBrush(Color.FromRgb(0xCA, 0x50, 0x10)),
        "BOOT THREAT" => new SolidColorBrush(Color.FromRgb(0x5C, 0x2D, 0x91)),
        "SUSPICIOUS" => new SolidColorBrush(Color.FromRgb(0x92, 0x68, 0x00)),
        _ => new SolidColorBrush(Color.FromRgb(0x00, 0x78, 0xD4))
      };
    }
  }
}
