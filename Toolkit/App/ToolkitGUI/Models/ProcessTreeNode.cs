using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace ToolkitGUI.Models
{
    public class ProcessTreeNode : INotifyPropertyChanged
    {
        public ProcessEntry? Entry { get; set; }
        public ObservableCollection<ProcessTreeNode> Children { get; } = new();

        public string DisplayName => Entry == null
            ? "(unknown)"
            : $"{Entry.Name} ({Entry.Pid})";

        public event PropertyChangedEventHandler? PropertyChanged;
        protected void OnPropertyChanged([CallerMemberName] string? n = null)
            => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
    }
}
