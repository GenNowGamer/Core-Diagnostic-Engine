using System;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using ToolkitGUI.Models;

namespace ToolkitGUI.Controls
{
    public partial class DiskMapControl : UserControl
    {
        public static readonly DependencyProperty DisksProperty =
            DependencyProperty.Register(nameof(Disks), typeof(ObservableCollection<CdePhysicalDiskModel>),
                typeof(DiskMapControl), new PropertyMetadata(null, OnDisksChanged));

        public static readonly DependencyProperty SelectedPartitionProperty =
            DependencyProperty.Register(nameof(SelectedPartition), typeof(CdePartitionModel),
                typeof(DiskMapControl), new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.BindsTwoWayByDefault));

        public static readonly RoutedEvent PartitionSelectedEvent =
            EventManager.RegisterRoutedEvent(nameof(PartitionSelected), RoutingStrategy.Bubble,
                typeof(RoutedEventHandler), typeof(DiskMapControl));

        public event RoutedEventHandler PartitionSelected
        {
            add => AddHandler(PartitionSelectedEvent, value);
            remove => RemoveHandler(PartitionSelectedEvent, value);
        }

        public ObservableCollection<CdePhysicalDiskModel> Disks
        {
            get => (ObservableCollection<CdePhysicalDiskModel>)GetValue(DisksProperty);
            set => SetValue(DisksProperty, value);
        }

        public CdePartitionModel? SelectedPartition
        {
            get => (CdePartitionModel?)GetValue(SelectedPartitionProperty);
            set => SetValue(SelectedPartitionProperty, value);
        }

        public DiskMapControl()
        {
            InitializeComponent();
        }

        private static void OnDisksChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        {
            if (d is not DiskMapControl control)
                return;

            if (e.OldValue is ObservableCollection<CdePhysicalDiskModel> oldCollection)
                oldCollection.CollectionChanged -= control.OnDisksCollectionChanged;

            if (e.NewValue is ObservableCollection<CdePhysicalDiskModel> newCollection)
                newCollection.CollectionChanged += control.OnDisksCollectionChanged;

            control.RebuildMap();
        }

        private void OnDisksCollectionChanged(object? sender, NotifyCollectionChangedEventArgs e) => RebuildMap();

        private void RebuildMap()
        {
            DiskMapPanel.Children.Clear();
            if (Disks == null || Disks.Count == 0)
            {
                DiskMapPanel.Children.Add(new TextBlock
                {
                    Text = "No disks detected. Click Refresh.",
                    Foreground = Brushes.Gray,
                    Margin = new Thickness(4)
                });
                return;
            }

            foreach (var disk in Disks)
            {
                var header = new TextBlock
                {
                    Text = $"Disk {disk.DiskNumber}  {disk.FriendlyName}  {disk.PartitionStyle}  {CdePartitionModel.FormatSize(disk.Size)}",
                    FontWeight = FontWeights.SemiBold,
                    Margin = new Thickness(0, 8, 0, 4)
                };
                DiskMapPanel.Children.Add(header);

                var bar = new Grid { Height = 36, Margin = new Thickness(0, 0, 0, 4) };
                bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

                var inner = new Grid();
                Grid.SetColumn(inner, 0);

                if (disk.Partitions == null || disk.Partitions.Count == 0)
                {
                    inner.Children.Add(CreateSegment(disk, null, 1.0, "Unallocated / unknown"));
                }
                else
                {
                    long total = disk.Size > 0 ? disk.Size : disk.Partitions.Sum(p => p.Size);
                    if (total <= 0) total = disk.Partitions.Sum(p => p.Size);

                    foreach (var part in disk.Partitions)
                    {
                        double weight = total > 0 ? Math.Max(part.Size / (double)total, 0.02) : 1.0 / disk.Partitions.Count;
                        inner.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(weight, GridUnitType.Star) });
                        var segment = CreateSegment(disk, part, weight, part.DisplayLabel);
                        Grid.SetColumn(segment, inner.ColumnDefinitions.Count - 1);
                        inner.Children.Add(segment);
                    }
                }

                bar.Children.Add(inner);
                DiskMapPanel.Children.Add(bar);
            }
        }

        private Border CreateSegment(CdePhysicalDiskModel disk, CdePartitionModel? part, double weight, string tooltip)
        {
            var border = new Border
            {
                Margin = new Thickness(1, 0, 1, 0),
                Background = PickBrush(part),
                BorderBrush = Brushes.DimGray,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(2),
                ToolTip = tooltip,
                Cursor = part == null ? Cursors.Arrow : Cursors.Hand,
                Child = new TextBlock
                {
                    Text = part == null ? "?" : ShortLabel(part),
                    Foreground = Brushes.White,
                    FontSize = 11,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    VerticalAlignment = VerticalAlignment.Center,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Margin = new Thickness(4, 0, 4, 0)
                }
            };

            if (part != null)
            {
                border.MouseLeftButtonUp += (_, _) =>
                {
                    SelectedPartition = part;
                    RaiseEvent(new RoutedEventArgs(PartitionSelectedEvent, part));
                };

                if (SelectedPartition != null &&
                    SelectedPartition.DriveRoot == part.DriveRoot &&
                    SelectedPartition.PartitionNumber == part.PartitionNumber)
                {
                    border.BorderBrush = Brushes.White;
                    border.BorderThickness = new Thickness(2);
                }
            }

            return border;
        }

        private static string ShortLabel(CdePartitionModel part)
        {
            if (!string.IsNullOrWhiteSpace(part.DriveLetter))
                return $"{part.DriveLetter}:";
            if (part.IsSystem) return "EFI";
            if (part.HasWindows) return "Win";
            return $"P{part.PartitionNumber}";
        }

        private static Brush PickBrush(CdePartitionModel? part)
        {
            if (part == null) return new SolidColorBrush(Color.FromRgb(80, 80, 80));
            if (part.HasWindows) return new SolidColorBrush(Color.FromRgb(0, 120, 212));
            if (part.IsSystem) return new SolidColorBrush(Color.FromRgb(16, 124, 16));
            if (part.IsBoot) return new SolidColorBrush(Color.FromRgb(0, 99, 177));
            if (part.Type.Contains("Recovery", StringComparison.OrdinalIgnoreCase))
                return new SolidColorBrush(Color.FromRgb(128, 128, 128));
            return new SolidColorBrush(Color.FromRgb(96, 96, 96));
        }
    }
}
