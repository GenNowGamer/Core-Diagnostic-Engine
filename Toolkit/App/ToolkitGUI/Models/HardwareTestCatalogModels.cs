using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace ToolkitGUI.Models
{
    public sealed class HardwareTestCatalogDto
    {
        [JsonPropertyName("version")]
        public int Version { get; set; }

        [JsonPropertyName("tests")]
        public List<HardwareTestEntryDto>? Tests { get; set; }
    }

    public sealed class HardwareTestEntryDto
    {
        [JsonPropertyName("id")]
        public string? Id { get; set; }

        [JsonPropertyName("displayName")]
        public string? DisplayName { get; set; }

        [JsonPropertyName("category")]
        public string? Category { get; set; }

        [JsonPropertyName("order")]
        public int Order { get; set; }

        [JsonPropertyName("profiles")]
        public HardwareTestProfilesDto? Profiles { get; set; }
    }

    public sealed class HardwareTestProfilesDto
    {
        [JsonPropertyName("quick")]
        public bool Quick { get; set; }

        [JsonPropertyName("extended")]
        public bool Extended { get; set; }
    }
}
