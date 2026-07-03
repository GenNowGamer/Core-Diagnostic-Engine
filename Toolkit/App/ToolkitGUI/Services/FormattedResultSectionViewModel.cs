using System.Collections.Generic;
using System.Linq;
using ToolkitGUI.Models;

namespace ToolkitGUI.Services
{
    public sealed class FormattedPropertyLineViewModel
    {
        public string Label { get; init; } = string.Empty;
        public string Value { get; init; } = string.Empty;
    }

    public sealed class FormattedResultSectionViewModel
    {
        public string Title { get; init; } = string.Empty;
        public IReadOnlyList<StructuredResultItemViewModel> Items { get; init; } = new List<StructuredResultItemViewModel>();
        public IReadOnlyList<string> Lines { get; init; } = new List<string>();
        public IReadOnlyList<FormattedPropertyLineViewModel> PropertyLines { get; init; } = new List<FormattedPropertyLineViewModel>();
        public bool HasTitle => !string.IsNullOrWhiteSpace(Title);
        public bool HasItems => Items.Count > 0;
        public bool HasLines => Lines.Count > 0;
        public bool HasPropertyLines => PropertyLines.Count > 0;
    }

    internal static class FormattedResultSectionMapper
    {
        public static IReadOnlyList<FormattedResultSectionViewModel> MapSections(FormattedWorkflowOutput formatted)
        {
            var sections = formatted.Sections
                .Select(section => new FormattedResultSectionViewModel
                {
                    Title = section.Title,
                    Items = section.Items
                        .Select(StructuredResultItemViewModel.FromFormattedItem)
                        .Where(item => !string.IsNullOrWhiteSpace(item.Name))
                        .ToList(),
                    Lines = section.Lines,
                    PropertyLines = section.Lines
                        .Select(ParsePropertyLine)
                        .Where(line => !string.IsNullOrWhiteSpace(line.Label))
                        .ToList()
                })
                .Where(section => section.HasItems || section.HasLines)
                .ToList();

            if (sections.Count > 0)
            {
                return sections;
            }

            var flatItems = formatted.AllItems
                .Select(StructuredResultItemViewModel.FromFormattedItem)
                .Where(item => !string.IsNullOrWhiteSpace(item.Name))
                .ToList();

            if (flatItems.Count > 0)
            {
                sections.Add(new FormattedResultSectionViewModel
                {
                    Title = "Technical details",
                    Items = flatItems
                });
            }

            return sections;
        }

        private static FormattedPropertyLineViewModel ParsePropertyLine(string line)
        {
            var colon = line.IndexOf(':');
            if (colon <= 0)
            {
                return new FormattedPropertyLineViewModel
                {
                    Label = string.Empty,
                    Value = line.Trim()
                };
            }

            return new FormattedPropertyLineViewModel
            {
                Label = line[..colon].Trim(),
                Value = line[(colon + 1)..].Trim()
            };
        }
    }
}
