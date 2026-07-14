using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows;
using System.Windows.Media;

namespace ToolkitGUI.Views
{
    public partial class CstRemediationProgressWindow : Window
    {
        private readonly ObservableCollection<CstRemediationProgressItem> _items = new();

        public CstRemediationProgressWindow()
        {
            InitializeComponent();
            ItemsList.ItemsSource = _items;
        }

        public void Initialize(string actionVerb, System.Collections.Generic.IEnumerable<CstRemediationProgressItem> items)
        {
            TitleText.Text = $"{actionVerb} selected findings";
            StatusText.Text = "Starting remediation...";
            _items.Clear();
            foreach (var item in items)
                _items.Add(item);

            ProgressBar.Value = 0;
            ProgressPercentText.Text = $"0 / {_items.Count}";
        }

        public void SetCurrent(int zeroBasedIndex, string statusText)
        {
            if (zeroBasedIndex < 0 || zeroBasedIndex >= _items.Count)
                return;

            for (var i = 0; i < _items.Count; i++)
            {
                if (i < zeroBasedIndex)
                    continue;
                if (i == zeroBasedIndex)
                {
                    _items[i].Status = "Working";
                    _items[i].StatusBrush = new SolidColorBrush(Color.FromRgb(0x1F, 0x6F, 0xEB));
                }
            }

            var done = zeroBasedIndex;
            var total = _items.Count;
            var pct = total == 0 ? 0 : (done * 100.0 / total);
            ProgressBar.Value = pct;
            ProgressPercentText.Text = $"{done} / {total} complete — now {statusText}";
            StatusText.Text = statusText;
            ItemsList.ScrollIntoView(_items[zeroBasedIndex]);
        }

        public void MarkResult(int zeroBasedIndex, bool succeeded, bool skipped, string successLabel = "Done", string? note = null)
        {
            if (zeroBasedIndex < 0 || zeroBasedIndex >= _items.Count)
                return;

            var item = _items[zeroBasedIndex];
            if (succeeded)
            {
                item.Status = successLabel;
                item.StatusBrush = new SolidColorBrush(Color.FromRgb(0x1F, 0x9D, 0x55));
            }
            else if (skipped)
            {
                item.Status = "Skipped";
                item.StatusBrush = new SolidColorBrush(Color.FromRgb(0xCA, 0x8A, 0x04));
            }
            else
            {
                item.Status = "Failed";
                item.StatusBrush = new SolidColorBrush(Color.FromRgb(0xDC, 0x26, 0x26));
            }

            if (!string.IsNullOrWhiteSpace(note))
                item.Location = note!;

            var completed = zeroBasedIndex + 1;
            var total = _items.Count;
            ProgressBar.Value = total == 0 ? 100 : (completed * 100.0 / total);
            ProgressPercentText.Text = $"{completed} / {total} complete";
        }

        public void SetFinished(string summary)
        {
            StatusText.Text = summary;
            ProgressBar.Value = 100;
            ProgressPercentText.Text = $"{_items.Count} / {_items.Count} complete";
        }
    }

    public sealed class CstRemediationProgressItem : INotifyPropertyChanged
    {
        private string _status = "Pending";
        private string _location = string.Empty;
        private Brush _statusBrush = new SolidColorBrush(Color.FromRgb(0x6B, 0x72, 0x80));

        public string Id { get; init; } = string.Empty;
        public string DisplayName { get; init; } = string.Empty;

        public string Location
        {
            get => _location;
            set
            {
                if (_location == value) return;
                _location = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Location)));
            }
        }

        public string Status
        {
            get => _status;
            set
            {
                if (_status == value) return;
                _status = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Status)));
            }
        }

        public Brush StatusBrush
        {
            get => _statusBrush;
            set
            {
                _statusBrush = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(StatusBrush)));
            }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
    }
}
