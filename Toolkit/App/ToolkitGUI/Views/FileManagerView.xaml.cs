using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using ToolkitGUI.Services;
using ToolkitGUI.ViewModels;

namespace ToolkitGUI.Views
{
    public partial class FileManagerView : UserControl
    {
        private enum Pane { Top, Bottom }

        private Pane _activePane = Pane.Top;
        private string _topPath = string.Empty;
        private string _bottomPath = string.Empty;
        private bool _splitViewEnabled;
        private bool _suppressTreeSelection;
        private CancellationTokenSource? _topFolderSizeCts;
        private CancellationTokenSource? _bottomFolderSizeCts;
        private static readonly SemaphoreSlim FolderSizeConcurrency = new(3, 3);
        private readonly Dictionary<Pane, PaneSortState> _sortStates = new();
        private List<string>? _clipboardPaths;
        private bool _clipboardIsCut;
        private bool _cstScanInProgress;

        public FileManagerView()
        {
            InitializeComponent();
            Unloaded += (_, _) => CancelAllFolderSizeEnumeration();
            TopItemsListView.View = CreateFileGridView(Pane.Top);
            BottomItemsListView.View = CreateFileGridView(Pane.Bottom);
            AttachColumnHeaderSorting(TopItemsListView, Pane.Top);
            AttachColumnHeaderSorting(BottomItemsListView, Pane.Bottom);
            _topPath = string.Empty;
            _bottomPath = string.Empty;
            InitializeFolderTree(TopFolderTree);
            InitializeFolderTree(BottomFolderTree);
            Loaded += OnFileManagerLoaded;
            ClearPane(Pane.Top);
            SetStatus("Select a drive or shadow copy to browse.");
        }

        private void OnFileManagerLoaded(object sender, RoutedEventArgs e)
        {
            ExpandComputerRoot(TopFolderTree);
            ExpandComputerRoot(BottomFolderTree);
        }

        private GridView CreateFileGridView(Pane pane)
        {
            var selectTemplate = (DataTemplate)Resources["FileSelectCellTemplate"];
            var nameTemplate = (DataTemplate)Resources["FileNameCellTemplate"];
            var state = GetSortState(pane);

            var selectAll = new CheckBox
            {
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
                ToolTip = "Select all",
                IsThreeState = true
            };
            selectAll.Click += (_, _) =>
            {
                if (GetSortState(pane).SuppressSelectAllHandler)
                    return;

                var items = GetAllItems(pane).ToList();
                var checkAll = items.Count == 0 || items.Any(i => !i.IsChecked);
                SetAllItemsChecked(pane, checkAll);
            };
            state.SelectAllCheckBox = selectAll;

            state.SelectColumn = new GridViewColumn { Header = selectAll, CellTemplate = selectTemplate, Width = 32 };
            state.NameColumn = new GridViewColumn { Header = "Name", CellTemplate = nameTemplate, Width = 260 };
            state.SizeColumn = new GridViewColumn { Header = "Size", DisplayMemberBinding = new Binding(nameof(FileItem.Size)), Width = 90 };
            state.TypeColumn = new GridViewColumn { Header = "Type", DisplayMemberBinding = new Binding(nameof(FileItem.Type)), Width = 130 };
            state.ModifiedColumn = new GridViewColumn { Header = "Modified", DisplayMemberBinding = new Binding(nameof(FileItem.Modified)), Width = 150 };
            UpdateColumnHeaderText(pane);

            return new GridView
            {
                Columns =
                {
                    state.SelectColumn,
                    state.NameColumn,
                    state.SizeColumn,
                    state.TypeColumn,
                    state.ModifiedColumn
                }
            };
        }

        private void AttachColumnHeaderSorting(ListView listView, Pane pane)
        {
            listView.AddHandler(
                GridViewColumnHeader.ClickEvent,
                new RoutedEventHandler((_, e) =>
                {
                    if (e.OriginalSource is not GridViewColumnHeader { Role: GridViewColumnHeaderRole.Normal } header)
                        return;

                    var column = header.Column switch
                    {
                        var c when c == GetSortState(pane).NameColumn => SortColumn.Name,
                        var c when c == GetSortState(pane).SizeColumn => SortColumn.Size,
                        var c when c == GetSortState(pane).TypeColumn => SortColumn.Type,
                        var c when c == GetSortState(pane).ModifiedColumn => SortColumn.Modified,
                        _ => (SortColumn?)null
                    };

                    if (column is null)
                        return;

                    ApplySort(pane, column.Value, toggleIfSame: true);
                    e.Handled = true;
                }));
        }

        private PaneSortState GetSortState(Pane pane)
        {
            if (!_sortStates.TryGetValue(pane, out var state))
            {
                state = new PaneSortState();
                _sortStates[pane] = state;
            }

            return state;
        }

        private void ApplySort(Pane pane, SortColumn column, bool toggleIfSame)
        {
            var state = GetSortState(pane);
            if (toggleIfSame && state.Column == column)
            {
                state.Direction = state.Direction == ListSortDirection.Ascending
                    ? ListSortDirection.Descending
                    : ListSortDirection.Ascending;
            }
            else
            {
                state.Column = column;
                state.Direction = column switch
                {
                    SortColumn.Size => ListSortDirection.Descending,
                    SortColumn.Modified => ListSortDirection.Descending,
                    _ => ListSortDirection.Ascending
                };
            }

            if (state.ItemsView is not null)
                ApplySortToView(state);

            UpdateColumnHeaderText(pane);
        }

        private static void ApplySortToView(PaneSortState state)
        {
            var propertyName = state.Column switch
            {
                SortColumn.Name => nameof(FileItem.NameSortKey),
                SortColumn.Size => nameof(FileItem.SizeBytes),
                SortColumn.Type => nameof(FileItem.TypeSortKey),
                SortColumn.Modified => nameof(FileItem.ModifiedAt),
                _ => nameof(FileItem.Name)
            };

            state.ItemsView!.SortDescriptions.Clear();
            state.ItemsView.SortDescriptions.Add(new SortDescription(nameof(FileItem.GroupOrder), ListSortDirection.Ascending));
            state.ItemsView.SortDescriptions.Add(new SortDescription(propertyName, state.Direction));
        }

        private void UpdateColumnHeaderText(Pane pane)
        {
            var state = GetSortState(pane);
            var arrow = state.Direction == ListSortDirection.Ascending ? " \u25B2" : " \u25BC";
            state.NameColumn.Header = state.Column == SortColumn.Name ? "Name" + arrow : "Name";
            state.SizeColumn.Header = state.Column == SortColumn.Size ? "Size" + arrow : "Size";
            state.TypeColumn.Header = state.Column == SortColumn.Type ? "Type" + arrow : "Type";
            state.ModifiedColumn.Header = state.Column == SortColumn.Modified ? "Modified" + arrow : "Modified";
        }

        private enum SortColumn
        {
            Name,
            Size,
            Type,
            Modified
        }

        private sealed class PaneSortState
        {
            public SortColumn Column = SortColumn.Name;
            public ListSortDirection Direction = ListSortDirection.Ascending;
            public ListCollectionView? ItemsView;
            public GridViewColumn SelectColumn = null!;
            public CheckBox? SelectAllCheckBox;
            public bool SuppressSelectAllHandler;
            public GridViewColumn NameColumn = null!;
            public GridViewColumn SizeColumn = null!;
            public GridViewColumn TypeColumn = null!;
            public GridViewColumn ModifiedColumn = null!;
        }

        private void InitializeFolderTree(TreeView tree)
        {
            tree.ItemsSource = new[] { BuildComputerRoot() };
            if (tree.IsLoaded)
                ExpandComputerRoot(tree);
        }

        private static void ExpandComputerRoot(TreeView tree)
        {
            if (tree.Items.Count == 0)
                return;

            tree.UpdateLayout();
            if (tree.ItemContainerGenerator.Status != System.Windows.Controls.Primitives.GeneratorStatus.ContainersGenerated)
            {
                void OnStatusChanged(object? _, EventArgs __)
                {
                    tree.ItemContainerGenerator.StatusChanged -= OnStatusChanged;
                    ExpandComputerRoot(tree);
                }

                tree.ItemContainerGenerator.StatusChanged += OnStatusChanged;
                return;
            }

            if (tree.ItemContainerGenerator.ContainerFromIndex(0) is TreeViewItem rootItem)
                rootItem.IsExpanded = true;
        }

        private static FolderTreeNode BuildComputerRoot()
        {
            var computer = new FolderTreeNode("Computer", null);

            foreach (var drive in DriveInfo.GetDrives())
            {
                if (!drive.IsReady)
                    continue;
                computer.Children.Add(FolderTreeNode.FromDrive(drive));
            }

            var offline = Environment.GetEnvironmentVariable("OFFLINE_WINDOWS_ROOT");
            if (!string.IsNullOrWhiteSpace(offline))
            {
                var path = offline.TrimEnd('\\');
                if (Directory.Exists(path))
                    computer.Children.Add(new FolderTreeNode("Offline OS", path));
            }

            var users = ResolveUsersPath();
            if (!string.IsNullOrEmpty(users))
                computer.Children.Add(new FolderTreeNode("Users", users));

            var toolkit = Environment.GetEnvironmentVariable("TOOLKIT_ROOT");
            if (!string.IsNullOrWhiteSpace(toolkit))
            {
                var path = toolkit.TrimEnd('\\');
                if (Directory.Exists(path))
                    computer.Children.Add(new FolderTreeNode("Toolkit", path));
            }

            if (ShadowCopyBrowseService.IsAvailable())
                computer.Children.Add(FolderTreeNode.CreateShadowCopiesRoot());

            return computer;
        }

        private static string? ResolveUsersPath()
        {
            var offline = Environment.GetEnvironmentVariable("OFFLINE_WINDOWS_ROOT");
            if (!string.IsNullOrWhiteSpace(offline))
            {
                var users = Path.Combine(offline.TrimEnd('\\'), "Users");
                if (Directory.Exists(users))
                    return users;
            }

            const string fallback = @"C:\Users";
            return Directory.Exists(fallback) ? fallback : null;
        }

        private void SplitView_Click(object sender, RoutedEventArgs e)
        {
            _splitViewEnabled = !_splitViewEnabled;

            if (_splitViewEnabled)
            {
                BottomPaneRow.Height = new GridLength(1, GridUnitType.Star);
                BottomPaneBorder.Visibility = Visibility.Visible;
                PaneSplitter.Visibility = Visibility.Visible;
                SplitViewButton.Content = "Close Split";
                if (BottomFolderTree.Items.Count == 0)
                    InitializeFolderTree(BottomFolderTree);
                ExpandComputerRoot(BottomFolderTree);
                ClearPane(Pane.Bottom);
            }
            else
            {
                BottomPaneRow.Height = new GridLength(0);
                BottomPaneBorder.Visibility = Visibility.Collapsed;
                PaneSplitter.Visibility = Visibility.Collapsed;
                SplitViewButton.Content = "Split View";
            }
        }

        private void TopFolderTree_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
            => OnFolderTreeSelected(Pane.Top, e.NewValue as FolderTreeNode);

        private void BottomFolderTree_SelectedItemChanged(object sender, RoutedPropertyChangedEventArgs<object> e)
            => OnFolderTreeSelected(Pane.Bottom, e.NewValue as FolderTreeNode);

        private void OnFolderTreeSelected(Pane pane, FolderTreeNode? node)
        {
            if (_suppressTreeSelection || node == null)
                return;

            if (node.IsShadowCopiesRoot)
                return;

            if (node.ShadowCopy != null)
            {
                _ = MountShadowCopyAndBrowseAsync(pane, node);
                return;
            }

            if (string.IsNullOrWhiteSpace(node.Path))
            {
                if (string.Equals(node.Display, "Computer", StringComparison.Ordinal))
                    ClearPane(pane);
                return;
            }

            if (!node.OpensPaneOnSelect)
                return;

            if (!Directory.Exists(node.Path))
            {
                SetStatus($"Path not found: {node.Path}");
                return;
            }

            LoadQuickPath(pane, node.Path);
        }

        private void FolderTreeItem_Expanded(object sender, RoutedEventArgs e)
        {
            if (e.OriginalSource is not TreeViewItem item || item.DataContext is not FolderTreeNode node)
                return;

            if (node.IsShadowCopiesRoot)
            {
                if (!node.ChildrenLoaded)
                    _ = LoadShadowCopiesAsync(node);
                return;
            }

            if (string.IsNullOrWhiteSpace(node.Path) || node.ChildrenLoaded)
                return;

            node.LoadChildFolders();
        }

        private async Task LoadShadowCopiesAsync(FolderTreeNode rootNode)
        {
            if (!rootNode.IsShadowCopiesRoot || rootNode.ChildrenLoaded)
                return;

            SetStatus("Loading shadow copies...");

            var (entries, error) = await ShadowCopyBrowseService.ListAsync().ConfigureAwait(true);
            if (!string.IsNullOrWhiteSpace(error))
            {
                rootNode.ResetLazyChildren();
                SetStatus($"Shadow copies unavailable: {error}");
                return;
            }

            rootNode.Children.Clear();

            if (entries.Count == 0)
            {
                rootNode.ChildrenLoaded = true;
                SetStatus("No shadow copies found on this system.");
                return;
            }

            foreach (var entry in entries)
            {
                var label = string.IsNullOrWhiteSpace(entry.DisplayLabel)
                    ? $"{entry.Drive} {entry.InstallDate}".Trim()
                    : entry.DisplayLabel;
                var child = FolderTreeNode.FromShadowCopy(label, entry);
                child.Parent = rootNode;
                rootNode.Children.Add(child);
            }

            rootNode.ChildrenLoaded = true;
            var copyWord = entries.Count == 1 ? "copy" : "copies";
            SetStatus($"Loaded {entries.Count} shadow {copyWord}. Select one to browse.");
        }

        private async Task MountShadowCopyAndBrowseAsync(Pane pane, FolderTreeNode node)
        {
            if (node.ShadowCopy == null)
                return;

            if (!string.IsNullOrWhiteSpace(node.Path) && Directory.Exists(node.Path))
            {
                LoadQuickPath(pane, node.Path);
                SetStatus($"Browsing shadow copy (read-only): {node.Path}");
                return;
            }

            SetStatus("Mounting shadow copy...");
            var (mountPath, error) = await ShadowCopyBrowseService.MountAsync(node.ShadowCopy).ConfigureAwait(true);
            if (string.IsNullOrWhiteSpace(mountPath))
            {
                SetStatus(string.IsNullOrWhiteSpace(error) ? "Failed to mount shadow copy." : error);
                return;
            }

            node.SetMountedPath(mountPath);
            LoadQuickPath(pane, mountPath);
            SetStatus($"Browsing shadow copy (read-only): {mountPath}");
        }

        private bool IsReadOnlyBrowsePath(string? path) => ShadowCopyBrowseService.IsShadowBrowsePath(path);

        private void TopLoad_Click(object sender, RoutedEventArgs e) => LoadPathFromBox(Pane.Top);
        private void BottomLoad_Click(object sender, RoutedEventArgs e) => LoadPathFromBox(Pane.Bottom);
        private void TopRefresh_Click(object sender, RoutedEventArgs e) => LoadDirectory(_topPath, Pane.Top);
        private void BottomRefresh_Click(object sender, RoutedEventArgs e) => LoadDirectory(_bottomPath, Pane.Bottom);
        private void TopUp_Click(object sender, RoutedEventArgs e) => NavigateUp(Pane.Top);
        private void BottomUp_Click(object sender, RoutedEventArgs e) => NavigateUp(Pane.Bottom);

        private void TopPathBox_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter)
                LoadPathFromBox(Pane.Top);
        }

        private void BottomPathBox_KeyDown(object sender, KeyEventArgs e)
        {
            if (e.Key == Key.Enter)
                LoadPathFromBox(Pane.Bottom);
        }

        private void TopPane_SelectionChanged(object sender, SelectionChangedEventArgs e) => _activePane = Pane.Top;
        private void BottomPane_SelectionChanged(object sender, SelectionChangedEventArgs e) => _activePane = Pane.Bottom;

        private void TopItemsListView_MouseDoubleClick(object sender, MouseButtonEventArgs e)
            => OpenOrNavigateSelected(Pane.Top, TopItemsListView);

        private void BottomItemsListView_MouseDoubleClick(object sender, MouseButtonEventArgs e)
            => OpenOrNavigateSelected(Pane.Bottom, BottomItemsListView);

        private void TopItemsListView_PreviewMouseRightButtonUp(object sender, MouseButtonEventArgs e)
            => ShowContextMenu(Pane.Top, TopItemsListView, e);

        private void BottomItemsListView_PreviewMouseRightButtonUp(object sender, MouseButtonEventArgs e)
            => ShowContextMenu(Pane.Bottom, BottomItemsListView, e);

        private void ShowContextMenu(Pane pane, ListView listView, MouseButtonEventArgs e)
        {
            _activePane = pane;

            if (FindAncestor<ListViewItem>(e.OriginalSource as DependencyObject)?.DataContext is FileItem clickedItem)
            {
                if (!clickedItem.IsChecked && !GetAllItems(pane).Any(i => i.IsChecked))
                {
                    clickedItem.IsChecked = true;
                }
                else if (!clickedItem.IsChecked)
                {
                    ClearAllItemsChecked(pane);
                    clickedItem.IsChecked = true;
                }

                if (!listView.SelectedItems.Contains(clickedItem))
                {
                    listView.SelectedItems.Clear();
                    listView.SelectedItem = clickedItem;
                }
            }

            var menu = FindAncestor<ListViewItem>(e.OriginalSource as DependencyObject)?.DataContext is FileItem
                ? BuildItemContextMenu(pane)
                : BuildBackgroundContextMenu(pane);

            menu.PlacementTarget = listView;
            menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint;
            menu.IsOpen = true;
            e.Handled = true;
        }

        private ContextMenu BuildItemContextMenu(Pane pane)
        {
            var menu = CreateStyledContextMenu();
            var selected = GetSelectedItems(pane).ToList();
            var readOnly = IsReadOnlyBrowsePath(GetPanePath(pane));
            var single = selected.Count == 1 ? selected[0] : null;

            menu.Items.Add(CreateMenuItem("Open", () => OpenOrNavigateSelected(pane, GetItemsListView(pane))));

            if (single?.IsDirectory == true && _splitViewEnabled)
            {
                menu.Items.Add(CreateMenuItem("Open in other pane", () =>
                {
                    var other = pane == Pane.Top ? Pane.Bottom : Pane.Top;
                    SetActivePath(other, single.FullPath);
                    LoadDirectory(single.FullPath, other);
                }));
            }

            menu.Items.Add(new Separator());

            if (!readOnly)
            {
                menu.Items.Add(CreateMenuItem("Cut", () => CutSelectedToClipboard(pane), selected.Count > 0));
                menu.Items.Add(CreateMenuItem("Copy", () => CopySelectedToClipboard(pane), selected.Count > 0));
            }

            menu.Items.Add(CreateMenuItem("Copy path", () => CopyPathsToClipboard(selected), selected.Count > 0));
            menu.Items.Add(CreateMenuItem(
                "Scan with CST",
                () => _ = ScanPathsWithCstAsync(selected.Select(i => i.FullPath).ToList()),
                selected.Count > 0 && !_cstScanInProgress));
            menu.Items.Add(new Separator());

            if (!readOnly)
            {
                menu.Items.Add(CreateMenuItem("Rename", () => RenameSelected(pane), single != null));
                menu.Items.Add(CreateMenuItem("Delete", () => DeleteSelectedInPane(pane), selected.Count > 0));
                menu.Items.Add(new Separator());
            }

            menu.Items.Add(CreateMenuItem("Properties", () => ShowProperties(selected), selected.Count > 0));
            menu.Items.Add(CreateMenuItem("Show in Windows Explorer", () => ShowInExplorer(selected), selected.Count > 0));

            return menu;
        }

        private ContextMenu BuildBackgroundContextMenu(Pane pane)
        {
            var menu = CreateStyledContextMenu();
            var folderPath = GetPanePath(pane);
            var readOnly = IsReadOnlyBrowsePath(folderPath);
            var hasPaste = !readOnly && _clipboardPaths is { Count: > 0 };

            if (!readOnly)
            {
                menu.Items.Add(CreateMenuItem("New folder", () => NewFolderInPane(pane)));
                menu.Items.Add(CreateMenuItem("Paste", () => PasteIntoPane(pane), hasPaste));
                menu.Items.Add(new Separator());
            }

            if (_splitViewEnabled)
            {
                menu.Items.Add(CreateMenuItem("Copy to other pane", () =>
                {
                    _activePane = pane;
                    CopyOrMoveSelected(copyOnly: true);
                }));
                menu.Items.Add(CreateMenuItem("Move to other pane", () =>
                {
                    _activePane = pane;
                    CopyOrMoveSelected(copyOnly: false);
                }, !readOnly));
                menu.Items.Add(new Separator());
            }

            menu.Items.Add(CreateMenuItem("Refresh", () => RefreshPane(pane)));
            menu.Items.Add(CreateMenuItem("Copy folder path", () =>
            {
                if (!string.IsNullOrWhiteSpace(folderPath))
                    Clipboard.SetText(folderPath);
            }, !string.IsNullOrWhiteSpace(folderPath)));
            menu.Items.Add(CreateMenuItem(
                "Scan this folder with CST",
                () => _ = ScanPathsWithCstAsync(new[] { folderPath }),
                !string.IsNullOrWhiteSpace(folderPath) && !_cstScanInProgress));
            menu.Items.Add(CreateMenuItem("Open in Windows Explorer", () =>
            {
                if (!string.IsNullOrWhiteSpace(folderPath))
                    OpenPathInExplorer(folderPath);
            }, !string.IsNullOrWhiteSpace(folderPath)));

            return menu;
        }

        private ContextMenu CreateStyledContextMenu()
        {
            return new ContextMenu
            {
                Background = (Brush)FindResource("BackgroundDarkBrush"),
                Foreground = (Brush)FindResource("TextPrimaryBrush"),
                BorderBrush = (Brush)FindResource("TextSecondaryBrush")
            };
        }

        private static MenuItem CreateMenuItem(string header, Action action, bool isEnabled = true)
        {
            var item = new MenuItem { Header = header, IsEnabled = isEnabled };
            item.Click += (_, _) => action();
            return item;
        }

        private void CutSelectedToClipboard(Pane pane)
        {
            var paths = GetSelectedItems(pane).Select(i => i.FullPath).ToList();
            if (paths.Count == 0)
                return;

            _clipboardPaths = paths;
            _clipboardIsCut = true;
            SetStatus($"Cut {paths.Count} item(s). Select a destination folder and choose Paste.");
        }

        private void CopySelectedToClipboard(Pane pane)
        {
            var paths = GetSelectedItems(pane).Select(i => i.FullPath).ToList();
            if (paths.Count == 0)
                return;

            _clipboardPaths = paths;
            _clipboardIsCut = false;
            SetStatus($"Copied {paths.Count} item(s) to clipboard.");
        }

        private void PasteIntoPane(Pane pane)
        {
            if (_clipboardPaths == null || _clipboardPaths.Count == 0)
            {
                SetStatus("Nothing to paste.");
                return;
            }

            var targetPath = GetPanePath(pane);
            if (IsReadOnlyBrowsePath(targetPath))
            {
                SetStatus("Shadow copy folders are read-only.");
                return;
            }

            if (!Directory.Exists(targetPath))
            {
                SetStatus("Current folder is invalid.");
                return;
            }

            try
            {
                var wasCut = _clipboardIsCut;
                foreach (var source in _clipboardPaths.ToList())
                {
                    if (!File.Exists(source) && !Directory.Exists(source))
                        continue;

                    var name = Path.GetFileName(source.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
                    if (string.IsNullOrEmpty(name))
                        continue;

                    var dest = GetUniquePath(Path.Combine(targetPath, name));
                    if (Directory.Exists(source))
                    {
                        CopyDirectory(source, dest);
                        if (_clipboardIsCut)
                            Directory.Delete(source, recursive: true);
                    }
                    else
                    {
                        File.Copy(source, dest);
                        if (_clipboardIsCut)
                            File.Delete(source);
                    }
                }

                if (_clipboardIsCut)
                {
                    _clipboardPaths = null;
                    _clipboardIsCut = false;
                }

                RefreshPane(pane);
                SetStatus(wasCut ? "Move complete." : "Paste complete.");
            }
            catch (Exception ex)
            {
                SetStatus($"Paste failed: {ex.Message}");
            }
        }

        private void RenameSelected(Pane pane)
        {
            if (IsReadOnlyBrowsePath(GetPanePath(pane)))
            {
                SetStatus("Shadow copy folders are read-only.");
                return;
            }

            var item = GetSelectedItems(pane).FirstOrDefault();
            if (item == null)
                return;

            var newName = PromptForText("Rename", "Enter a new name:", item.Name);
            if (string.IsNullOrWhiteSpace(newName) ||
                string.Equals(newName.Trim(), item.Name, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            newName = newName.Trim();
            if (newName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            {
                SetStatus("The name contains invalid characters.");
                return;
            }

            var parent = Path.GetDirectoryName(item.FullPath) ?? string.Empty;
            var dest = Path.Combine(parent, newName);
            if (File.Exists(dest) || Directory.Exists(dest))
            {
                SetStatus("An item with that name already exists.");
                return;
            }

            try
            {
                if (item.IsDirectory)
                    Directory.Move(item.FullPath, dest);
                else
                    File.Move(item.FullPath, dest);

                RefreshPane(pane);
                SetStatus("Renamed item.");
            }
            catch (Exception ex)
            {
                SetStatus($"Rename failed: {ex.Message}");
            }
        }

        private void DeleteSelectedInPane(Pane pane)
        {
            _activePane = pane;
            DeleteSelected_Click(this, new RoutedEventArgs());
        }

        private void NewFolderInPane(Pane pane)
        {
            _activePane = pane;
            NewFolder_Click(this, new RoutedEventArgs());
        }

        private static void CopyPathsToClipboard(IReadOnlyList<FileItem> items)
        {
            if (items.Count == 0)
                return;

            Clipboard.SetText(string.Join(Environment.NewLine, items.Select(i => i.FullPath)));
        }

        private static void ShowProperties(IReadOnlyList<FileItem> items)
        {
            if (items.Count == 0)
                return;

            if (items.Count == 1)
            {
                var item = items[0];
                MessageBox.Show(
                    $"Name: {item.Name}\nType: {item.Type}\nSize: {item.Size}\nModified: {item.Modified}\n\nLocation:\n{item.FullPath}",
                    "Properties",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            MessageBox.Show(
                $"{items.Count} items selected.",
                "Properties",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }

        private static void ShowInExplorer(IReadOnlyList<FileItem> items)
        {
            if (items.Count == 0)
                return;

            var path = items[0].FullPath;
            if (items.Count == 1 && !items[0].IsDirectory)
            {
                Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"")
                {
                    UseShellExecute = true
                });
                return;
            }

            OpenPathInExplorer(items[0].IsDirectory ? path : Path.GetDirectoryName(path) ?? path);
        }

        private async Task ScanPathsWithCstAsync(IReadOnlyList<string> paths)
        {
            if (_cstScanInProgress)
            {
                SetStatus("A CST scan is already running.");
                return;
            }

            var targets = paths
                .Where(p => !string.IsNullOrWhiteSpace(p))
                .Select(p => p.Trim())
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .Where(p => File.Exists(p) || Directory.Exists(p))
                .ToList();

            if (targets.Count == 0)
            {
                SetStatus("Select an existing file or folder to scan with CST.");
                MessageBox.Show(
                    "Select an existing file or folder to scan with CST.",
                    "CST Scan",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            _cstScanInProgress = true;
            var displayName = targets.Count == 1
                ? Path.GetFileName(targets[0].TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar))
                : $"{targets.Count} items";
            if (string.IsNullOrWhiteSpace(displayName))
                displayName = targets[0];

            SetStatus($"Running CST scan on {displayName}...");
            string? pathsFile = null;
            try
            {
                var cstDir = ReportPathHelper.GetCstDataRoot();
                Directory.CreateDirectory(cstDir);
                pathsFile = Path.Combine(cstDir, $"path_scan_{DateTime.UtcNow:yyyyMMdd_HHmmss_fff}.json");
                var payload = new { targets };
                await File.WriteAllTextAsync(pathsFile, JsonSerializer.Serialize(payload));

                var script = WorkflowViewModelBase.GetScriptPath("ProcessAnalyzer.ps1");
                var owner = Window.GetWindow(this)
                    ?? Application.Current?.Windows.OfType<Window>().FirstOrDefault(window => window.IsActive);
                var primaryPath = targets[0];
                var parameters = $"-Action PathCstScan -TargetPathsFile \"{pathsFile}\"";

                ProcessAnalyzerCstResultService.ShowLiveScan(
                    owner,
                    displayName,
                    primaryPath,
                    targets.Count == 1 && Directory.Exists(primaryPath)
                        ? "Folder CustomScan"
                        : targets.Count > 1
                            ? "Multi-path CustomScan"
                            : "File CustomScan",
                    isStartupEntryScan: false,
                    script,
                    parameters,
                    (presentation, rawOutput) =>
                    {
                        var artifactPath = CstStructuredResultsService.ResolveArtifactPathFromStepOutput(rawOutput);
                        WorkOrderService.TryRecordCstScanRun(
                            artifactPath, primaryPath, presentation.Verdict, presentation.ReportPdfPath);
                        SetStatus("CST scan completed.");
                    },
                    onFinished: () =>
                    {
                        try
                        {
                            if (!string.IsNullOrWhiteSpace(pathsFile) && File.Exists(pathsFile))
                                File.Delete(pathsFile);
                        }
                        catch
                        {
                            // Best-effort cleanup of temp metadata.
                        }
                    });
            }
            catch (Exception ex)
            {
                SetStatus($"CST scan error: {ex.Message}");
                MessageBox.Show(ex.Message, "CST Scan", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            finally
            {
                _cstScanInProgress = false;
            }
        }

        private static void OpenPathInExplorer(string path)
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"")
            {
                UseShellExecute = true
            });
        }

        private static string? PromptForText(string title, string prompt, string defaultValue)
        {
            var owner = Application.Current?.MainWindow;
            var dialog = new Window
            {
                Title = title,
                Width = 420,
                Height = 150,
                WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen,
                Owner = owner,
                ResizeMode = ResizeMode.NoResize,
                Background = (Brush)Application.Current.FindResource("BackgroundDarkBrush")
            };
            WindowSizingHelper.EnableAdaptiveDialog(dialog);

            var promptBlock = new TextBlock
            {
                Text = prompt,
                Margin = new Thickness(12, 12, 12, 0),
                Foreground = (Brush)Application.Current.FindResource("TextPrimaryBrush")
            };
            var input = new TextBox
            {
                Text = defaultValue,
                Margin = new Thickness(12, 8, 12, 0),
                Height = 28
            };
            var buttons = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(12)
            };
            var ok = new Button { Content = "OK", Width = 80, Margin = new Thickness(0, 0, 8, 0), IsDefault = true };
            var cancel = new Button { Content = "Cancel", Width = 80, IsCancel = true };
            buttons.Children.Add(ok);
            buttons.Children.Add(cancel);

            var layout = new Grid();
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(promptBlock, 0);
            Grid.SetRow(input, 1);
            Grid.SetRow(buttons, 2);
            layout.Children.Add(promptBlock);
            layout.Children.Add(input);
            layout.Children.Add(buttons);
            dialog.Content = layout;

            string? result = null;
            ok.Click += (_, _) =>
            {
                result = input.Text;
                dialog.DialogResult = true;
            };
            cancel.Click += (_, _) => dialog.DialogResult = false;
            input.SelectAll();
            input.Focus();

            return dialog.ShowDialog() == true ? result : null;
        }

        private static T? FindAncestor<T>(DependencyObject? current) where T : DependencyObject
        {
            while (current != null)
            {
                if (current is T match)
                    return match;

                current = VisualTreeHelper.GetParent(current);
            }

            return null;
        }

        private void OpenSelected_Click(object sender, RoutedEventArgs e)
        {
            var selected = GetSelectedItems(_activePane).ToList();
            if (!selected.Any())
            {
                SetStatus("Select an item to open.");
                return;
            }

            foreach (var item in selected)
            {
                if (item.IsDirectory)
                {
                    SetActivePath(_activePane, item.FullPath);
                    LoadDirectory(item.FullPath, _activePane);
                }
                else
                {
                    try
                    {
                        ShellFileOpenHelper.OpenWithDefaultApplication(item.FullPath);
                    }
                    catch (Exception ex)
                    {
                        SetStatus($"Unable to open: {ex.Message}");
                    }
                }
            }
        }

        private void CopySelected_Click(object sender, RoutedEventArgs e) => CopyOrMoveSelected(copyOnly: true);
        private void MoveSelected_Click(object sender, RoutedEventArgs e) => CopyOrMoveSelected(copyOnly: false);

        private void DeleteSelected_Click(object sender, RoutedEventArgs e)
        {
            if (IsReadOnlyBrowsePath(GetPanePath(_activePane)))
            {
                SetStatus("Shadow copy folders are read-only.");
                return;
            }

            var selected = GetSelectedItems(_activePane).ToList();
            if (!selected.Any())
            {
                SetStatus("Select items to delete.");
                return;
            }

            if (MessageBox.Show($"Delete {selected.Count} item(s)?", "Confirm Delete", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
                return;

            try
            {
                foreach (var item in selected)
                {
                    if (item.IsDirectory)
                        Directory.Delete(item.FullPath, recursive: true);
                    else
                        File.Delete(item.FullPath);
                }
                RefreshPane(_activePane);
                SetStatus("Deleted selected item(s).");
            }
            catch (Exception ex)
            {
                SetStatus($"Delete failed: {ex.Message}");
            }
        }

        private void NewFolder_Click(object sender, RoutedEventArgs e)
        {
            var targetPath = GetPanePath(_activePane);
            if (IsReadOnlyBrowsePath(targetPath))
            {
                SetStatus("Shadow copy folders are read-only.");
                return;
            }

            if (!Directory.Exists(targetPath))
            {
                SetStatus("Current folder is invalid.");
                return;
            }

            try
            {
                var newFolder = Path.Combine(targetPath, "New Folder");
                newFolder = GetUniquePath(newFolder);
                Directory.CreateDirectory(newFolder);
                RefreshPane(_activePane);
                SetStatus("Created new folder.");
            }
            catch (Exception ex)
            {
                SetStatus($"Unable to create folder: {ex.Message}");
            }
        }

        private void LoadPathFromBox(Pane pane)
        {
            var path = GetPathBox(pane).Text.Trim();
            if (!Directory.Exists(path))
            {
                SetStatus("Path not found.");
                return;
            }

            SetActivePath(pane, path);
            LoadDirectory(path, pane);
        }

        private void NavigateUp(Pane pane)
        {
            var currentPath = GetPanePath(pane);
            if (string.IsNullOrWhiteSpace(currentPath))
                return;

            if (IsDriveRoot(currentPath))
            {
                SetStatus("Already at drive root.");
                return;
            }

            var parent = Directory.GetParent(currentPath);
            if (parent != null)
            {
                SetActivePath(pane, parent.FullName);
                LoadDirectory(parent.FullName, pane);
            }
        }

        private void OpenOrNavigateSelected(Pane pane, ListView listView)
        {
            if (listView.SelectedItem is not FileItem selected)
                return;

            if (selected.IsDirectory)
            {
                SetActivePath(pane, selected.FullPath);
                LoadDirectory(selected.FullPath, pane);
            }
            else
            {
                try
                {
                    ShellFileOpenHelper.OpenWithDefaultApplication(selected.FullPath);
                }
                catch (Exception ex)
                {
                    SetStatus($"Unable to open file: {ex.Message}");
                }
            }
        }

        private void CopyOrMoveSelected(bool copyOnly)
        {
            if (!_splitViewEnabled)
            {
                SetStatus("Enable Split View to copy or move to another folder.");
                return;
            }

            if (!copyOnly && IsReadOnlyBrowsePath(GetPanePath(_activePane)))
            {
                SetStatus("Items in a shadow copy cannot be moved.");
                return;
            }

            if (IsReadOnlyBrowsePath(GetPanePath(_activePane == Pane.Top ? Pane.Bottom : Pane.Top)))
            {
                SetStatus("Cannot copy or move items into a shadow copy folder.");
                return;
            }

            var source = _activePane;
            var destination = source == Pane.Top ? Pane.Bottom : Pane.Top;
            var selected = GetSelectedItems(source).ToList();
            if (!selected.Any())
            {
                SetStatus(copyOnly ? "Select items to copy." : "Select items to move.");
                return;
            }

            var targetFolder = GetPanePath(destination);
            if (!Directory.Exists(targetFolder))
            {
                SetStatus("Target folder is invalid.");
                return;
            }

            try
            {
                foreach (var item in selected)
                {
                    var dest = Path.Combine(targetFolder, item.Name);
                    dest = GetUniquePath(dest);

                    if (item.IsDirectory)
                    {
                        CopyDirectory(item.FullPath, dest);
                        if (!copyOnly)
                            Directory.Delete(item.FullPath, recursive: true);
                    }
                    else
                    {
                        File.Copy(item.FullPath, dest);
                        if (!copyOnly)
                            File.Delete(item.FullPath);
                    }
                }

                RefreshPane(destination);
                RefreshPane(source);
                SetStatus(copyOnly ? "Copy complete." : "Move complete.");
            }
            catch (Exception ex)
            {
                SetStatus($"Operation failed: {ex.Message}");
            }
        }

        private static void CopyDirectory(string sourceDir, string targetDir)
        {
            var dirInfo = new DirectoryInfo(sourceDir);
            Directory.CreateDirectory(targetDir);

            foreach (var file in dirInfo.GetFiles())
                file.CopyTo(Path.Combine(targetDir, file.Name));

            foreach (var subDir in dirInfo.GetDirectories())
                CopyDirectory(subDir.FullName, Path.Combine(targetDir, subDir.Name));
        }

        private void RefreshPane(Pane pane)
        {
            var currentPath = GetPanePath(pane);
            if (!Directory.Exists(currentPath))
                return;
            LoadDirectory(currentPath, pane);
        }

        private IEnumerable<FileItem> GetSelectedItems(Pane pane)
        {
            var checkedItems = GetAllItems(pane).Where(i => i.IsChecked).ToList();
            if (checkedItems.Count > 0)
                return checkedItems;

            var listView = GetItemsListView(pane);
            return listView.SelectedItems.Cast<FileItem>();
        }

        private IEnumerable<FileItem> GetAllItems(Pane pane)
        {
            var state = GetSortState(pane);
            if (state.ItemsView != null)
                return state.ItemsView.Cast<FileItem>();

            return GetItemsListView(pane).Items.Cast<FileItem>();
        }

        private void SetAllItemsChecked(Pane pane, bool isChecked)
        {
            foreach (var item in GetAllItems(pane))
                item.IsChecked = isChecked;

            UpdatePaneSelectionCount(pane);
        }

        private void ClearAllItemsChecked(Pane pane)
        {
            foreach (var item in GetAllItems(pane).Where(i => i.IsChecked))
                item.IsChecked = false;

            UpdateSelectAllCheckBox(pane);
        }

        private void UpdateSelectAllCheckBox(Pane pane)
        {
            var state = GetSortState(pane);
            if (state.SelectAllCheckBox == null)
                return;

            var items = GetAllItems(pane).ToList();
            if (items.Count == 0)
            {
                state.SuppressSelectAllHandler = true;
                try
                {
                    state.SelectAllCheckBox.IsChecked = false;
                }
                finally
                {
                    state.SuppressSelectAllHandler = false;
                }

                return;
            }

            var checkedCount = items.Count(i => i.IsChecked);
            state.SuppressSelectAllHandler = true;
            try
            {
                state.SelectAllCheckBox.IsChecked = checkedCount switch
                {
                    0 => false,
                    _ when checkedCount == items.Count => true,
                    _ => null
                };
            }
            finally
            {
                state.SuppressSelectAllHandler = false;
            }
        }

        private void UpdatePaneSelectionCount(Pane pane)
        {
            UpdateSelectAllCheckBox(pane);

            var total = GetAllItems(pane).Count();
            var selected = GetAllItems(pane).Count(i => i.IsChecked);
            var countText = selected > 0
                ? $"{total} item(s), {selected} selected"
                : $"{total} item(s)";

            if (pane == Pane.Top)
                TopPaneCountText.Text = countText;
            else
                BottomPaneCountText.Text = countText;
        }

        private void AttachItemCheckHandlers(Pane pane, IEnumerable<FileItem> items)
        {
            foreach (var item in items)
            {
                item.PropertyChanged += (_, e) =>
                {
                    if (e.PropertyName == nameof(FileItem.IsChecked))
                        UpdatePaneSelectionCount(pane);
                };
            }
        }

        private void ClearPane(Pane pane)
        {
            if (pane == Pane.Top)
                _topPath = string.Empty;
            else
                _bottomPath = string.Empty;

            CancelFolderSizeEnumeration(pane);
            GetPathBox(pane).Text = string.Empty;
            GetAddressText(pane).Text = "Computer";
            GetItemsListView(pane).ItemsSource = null;
            GetSortState(pane).ItemsView = null;

            if (pane == Pane.Top)
                TopPaneCountText.Text = "0 item(s)";
            else
                BottomPaneCountText.Text = "0 item(s)";
        }

        private void LoadDirectory(string path, Pane pane)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                ClearPane(pane);
                return;
            }

            if (!Directory.Exists(path))
            {
                SetStatus($"Unable to load folder: {path}");
                return;
            }

            var directories = new List<FileItem>();
            var files = new List<FileItem>();
            var skippedCount = 0;

            try
            {
                foreach (var dirPath in Directory.EnumerateDirectories(path))
                {
                    DirectoryInfo dirInfo;
                    try
                    {
                        dirInfo = new DirectoryInfo(dirPath);
                        _ = dirInfo.Attributes;
                    }
                    catch
                    {
                        skippedCount++;
                        continue;
                    }

                    if (dirInfo.Attributes.HasFlag(FileAttributes.ReparsePoint))
                    {
                        skippedCount++;
                        continue;
                    }

                    var modifiedAt = TryGetLastWriteUtc(dirInfo.FullName);
                    directories.Add(new FileItem(
                        dirInfo.Name,
                        dirInfo.FullName,
                        true,
                        "File folder",
                        FormatLastWriteText(modifiedAt),
                        modifiedAt,
                        "...",
                        FileItem.PendingFolderSizeBytes,
                        FileItem.GroupDirectories,
                        ShellIconHelper.GetIcon(dirInfo.FullName, isDirectory: true)));
                }
            }
            catch (Exception ex)
            {
                skippedCount++;
                SetStatus($"Directory enumeration warning: {ex.Message}");
            }

            try
            {
                foreach (var filePath in Directory.EnumerateFiles(path))
                {
                    FileInfo fileInfo;
                    try
                    {
                        fileInfo = new FileInfo(filePath);
                        _ = fileInfo.Attributes;
                    }
                    catch
                    {
                        skippedCount++;
                        continue;
                    }

                    var modifiedAt = TryGetLastWriteUtc(fileInfo.FullName);
                    var typeText = FormatFileType(fileInfo);
                    files.Add(new FileItem(
                        fileInfo.Name,
                        fileInfo.FullName,
                        false,
                        typeText,
                        FormatLastWriteText(modifiedAt),
                        modifiedAt,
                        SizeDisplayFormatter.FormatBytes(fileInfo.Length),
                        fileInfo.Length,
                        FileItem.GroupFiles,
                        ShellIconHelper.GetIcon(fileInfo.FullName, isDirectory: false)));
                }
            }
            catch (Exception ex)
            {
                skippedCount++;
                SetStatus($"File enumeration warning: {ex.Message}");
            }

            SetPaneState(pane, path, directories, files);

            SetStatus(skippedCount > 0
                ? $"Loaded {directories.Count + files.Count} item(s) from {path} ({skippedCount} skipped)."
                : $"Loaded {directories.Count + files.Count} item(s) from {path}.");
        }

        private static string FormatFileType(FileInfo fileInfo)
        {
            var ext = fileInfo.Extension;
            if (string.IsNullOrEmpty(ext))
                return "File";
            return ext.TrimStart('.').ToUpperInvariant() + " File";
        }

        private string GetPanePath(Pane pane) => pane == Pane.Top ? _topPath : _bottomPath;

        private void SetActivePath(Pane pane, string path)
        {
            if (pane == Pane.Top)
                _topPath = path;
            else
                _bottomPath = path;
        }

        private TextBox GetPathBox(Pane pane) => pane == Pane.Top ? TopPathBox : BottomPathBox;

        private ListView GetItemsListView(Pane pane) => pane == Pane.Top ? TopItemsListView : BottomItemsListView;

        private TreeView GetFolderTree(Pane pane) => pane == Pane.Top ? TopFolderTree : BottomFolderTree;

        private TextBlock GetAddressText(Pane pane) => pane == Pane.Top ? TopAddressText : BottomAddressText;

        private void SetPaneState(Pane pane, string path, List<FileItem> directories, List<FileItem> files)
        {
            if (pane == Pane.Top)
                _topPath = path;
            else
                _bottomPath = path;

            GetPathBox(pane).Text = path;
            GetAddressText(pane).Text = FormatAddress(path);
            BindGroupedList(pane, GetItemsListView(pane), directories, files);
            StartFolderSizeEnumeration(pane, directories);
            SyncTreeSelection(pane, path);
        }

        private void CancelAllFolderSizeEnumeration()
        {
            CancelFolderSizeEnumeration(Pane.Top);
            CancelFolderSizeEnumeration(Pane.Bottom);
        }

        private void CancelFolderSizeEnumeration(Pane pane)
        {
            ref var cts = ref (pane == Pane.Top ? ref _topFolderSizeCts : ref _bottomFolderSizeCts);
            cts?.Cancel();
            cts?.Dispose();
            cts = null;
        }

        private void StartFolderSizeEnumeration(Pane pane, IReadOnlyList<FileItem> directories)
        {
            CancelFolderSizeEnumeration(pane);
            if (directories.Count == 0)
                return;

            var cts = new CancellationTokenSource();
            if (pane == Pane.Top)
                _topFolderSizeCts = cts;
            else
                _bottomFolderSizeCts = cts;

            var token = cts.Token;

            foreach (var item in directories)
            {
                _ = EnumerateFolderSizeAsync(item, token);
            }
        }

        private async Task EnumerateFolderSizeAsync(FileItem item, CancellationToken token)
        {
            await FolderSizeConcurrency.WaitAsync(token).ConfigureAwait(false);
            try
            {
                var progress = new Progress<long>(bytes =>
                {
                    if (token.IsCancellationRequested)
                        return;

                    _ = Dispatcher.BeginInvoke(() =>
                    {
                        if (!token.IsCancellationRequested)
                            item.UpdateSize(bytes);
                    });
                });

                var total = await FolderSizeCalculator.CalculateAsync(
                    item.FullPath,
                    progress,
                    token).ConfigureAwait(false);

                if (token.IsCancellationRequested)
                    return;

                await Dispatcher.InvokeAsync(() =>
                {
                    if (!token.IsCancellationRequested)
                        item.UpdateSize(total);
                });
            }
            catch (OperationCanceledException)
            {
                // Navigation changed; ignore.
            }
            finally
            {
                FolderSizeConcurrency.Release();
            }
        }

        private void BindGroupedList(Pane pane, ListView listView, List<FileItem> directories, List<FileItem> files)
        {
            var combined = new List<FileItem>(directories.Count + files.Count);
            combined.AddRange(directories);
            combined.AddRange(files);
            AttachItemCheckHandlers(pane, combined);

            var view = new ListCollectionView(combined);
            view.GroupDescriptions.Add(new PropertyGroupDescription(nameof(FileItem.GroupName)));

            var state = GetSortState(pane);
            state.ItemsView = view;
            ApplySortToView(state);
            UpdateColumnHeaderText(pane);
            listView.ItemsSource = view;
            UpdatePaneSelectionCount(pane);
        }

        private static string FormatAddress(string path)
        {
            if (string.IsNullOrWhiteSpace(path))
                return "Computer";

            try
            {
                var full = Path.GetFullPath(path);
                if (ShadowCopyBrowseService.IsShadowBrowsePath(full))
                {
                    var mountRoot = Path.Combine(Path.GetTempPath(), "CDE_ShadowBrowse");
                    var relative = full.Length > mountRoot.Length
                        ? full.Substring(mountRoot.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                        : string.Empty;
                    return string.IsNullOrWhiteSpace(relative)
                        ? "Shadow Copies"
                        : $"Shadow Copies > {relative.Replace(Path.DirectorySeparatorChar, ' ').Replace(Path.AltDirectorySeparatorChar, ' ')}";
                }

                var root = Path.GetPathRoot(full);
                if (string.IsNullOrEmpty(root))
                    return path;

                var parts = new List<string> { "Computer", root.TrimEnd('\\') };
                var remainder = full.Substring(root.Length).Trim('\\');
                if (!string.IsNullOrEmpty(remainder))
                    parts.AddRange(remainder.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));

                return string.Join(" > ", parts);
            }
            catch
            {
                return path;
            }
        }

        private void SyncTreeSelection(Pane pane, string path)
        {
            if (string.IsNullOrWhiteSpace(path))
                return;

            var tree = GetFolderTree(pane);
            if (tree.Items.Count == 0)
                return;

            if (tree.Items[0] is not FolderTreeNode computer)
                return;

            var target = EnsureTreePathExpanded(computer, path);
            if (target == null)
                return;

            _suppressTreeSelection = true;
            try
            {
                tree.UpdateLayout();
                SelectTreeViewItem(tree, target);
            }
            finally
            {
                _suppressTreeSelection = false;
            }
        }

        private FolderTreeNode? EnsureTreePathExpanded(FolderTreeNode computer, string path)
        {
            var full = TryGetFullPath(path).TrimEnd('\\');
            var root = Path.GetPathRoot(full);
            if (string.IsNullOrEmpty(root))
                return null;

            var driveRoot = root.TrimEnd('\\');
            var current = computer.Children.FirstOrDefault(c =>
                c.Path != null &&
                string.Equals(TryGetFullPath(c.Path).TrimEnd('\\'), driveRoot, StringComparison.OrdinalIgnoreCase));

            if (current == null)
                return null;

            current.LoadChildFolders();

            var remainder = full.Length > root.Length ? full.Substring(root.Length).Trim('\\') : string.Empty;
            if (string.IsNullOrEmpty(remainder))
                return current;

            foreach (var segment in remainder.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar))
            {
                current.LoadChildFolders();
                var next = current.Children.FirstOrDefault(c =>
                    string.Equals(c.Display, segment, StringComparison.OrdinalIgnoreCase));
                if (next == null)
                    return current;
                current = next;
            }

            return current;
        }

        private static void SelectTreeViewItem(ItemsControl parent, FolderTreeNode target)
        {
            if (parent.ItemContainerGenerator.ContainerFromItem(target) is TreeViewItem container)
            {
                container.IsSelected = true;
                container.BringIntoView();
                return;
            }

            foreach (var item in parent.Items)
            {
                if (parent.ItemContainerGenerator.ContainerFromItem(item) is not TreeViewItem childContainer)
                    continue;

                childContainer.UpdateLayout();
                if (item == target)
                {
                    childContainer.IsSelected = true;
                    childContainer.BringIntoView();
                    return;
                }

                SelectTreeViewItem(childContainer, target);
            }
        }

        private static string TryGetFullPath(string path)
        {
            try
            {
                return Path.GetFullPath(path);
            }
            catch
            {
                return path;
            }
        }

        private static bool IsWinPeMode() => Directory.Exists(@"X:\");

        private static bool IsDriveRoot(string path)
        {
            try
            {
                var full = Path.GetFullPath(path);
                var root = Path.GetPathRoot(full)?.TrimEnd('\\');
                return !string.IsNullOrEmpty(root) &&
                       string.Equals(full.TrimEnd('\\'), root, StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        private static DateTime TryGetLastWriteUtc(string fullPath)
        {
            try
            {
                return File.GetLastWriteTimeUtc(fullPath);
            }
            catch
            {
                return DateTime.MinValue;
            }
        }

        private static string FormatLastWriteText(DateTime modifiedUtc)
        {
            if (modifiedUtc == DateTime.MinValue)
                return string.Empty;

            return modifiedUtc.ToLocalTime().ToString("g");
        }

        private void LoadQuickPath(Pane pane, string path)
        {
            if (!Directory.Exists(path))
            {
                SetStatus($"Path not found: {path}");
                return;
            }

            SetActivePath(pane, path);
            LoadDirectory(path, pane);
        }

        private static string GetUniquePath(string path)
        {
            if (!File.Exists(path) && !Directory.Exists(path))
                return path;

            var directory = Path.GetDirectoryName(path) ?? string.Empty;
            var filename = Path.GetFileNameWithoutExtension(path);
            var extension = Path.GetExtension(path);
            var counter = 1;

            string candidate;
            do
            {
                candidate = Path.Combine(directory, $"{filename} ({counter}){extension}");
                counter++;
            } while (File.Exists(candidate) || Directory.Exists(candidate));

            return candidate;
        }

        private void SetStatus(string message) => StatusText.Text = message;

        private sealed class FileItem : INotifyPropertyChanged
        {
            public const string GroupDirectories = "Directories";
            public const string GroupFiles = "Files";
            public const long PendingFolderSizeBytes = long.MaxValue;

            public string Name { get; }
            public string NameSortKey { get; }
            public string FullPath { get; }
            public bool IsDirectory { get; }
            public string Type { get; }
            public string TypeSortKey { get; }
            public string Modified { get; }
            public DateTime ModifiedAt { get; }
            public string GroupName { get; }
            public int GroupOrder { get; }
            public ImageSource Icon { get; }

            private string _size;
            public string Size
            {
                get => _size;
                private set
                {
                    if (_size == value)
                        return;
                    _size = value;
                    PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Size)));
                }
            }

            private long _sizeBytes;
            public long SizeBytes
            {
                get => _sizeBytes;
                private set
                {
                    if (_sizeBytes == value)
                        return;
                    _sizeBytes = value;
                    PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(SizeBytes)));
                }
            }

            private bool _isChecked;
            public bool IsChecked
            {
                get => _isChecked;
                set
                {
                    if (_isChecked == value)
                        return;
                    _isChecked = value;
                    PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsChecked)));
                }
            }

            public FileItem(
                string name,
                string fullPath,
                bool isDirectory,
                string type,
                string modified,
                DateTime modifiedAt,
                string size,
                long sizeBytes,
                string groupName,
                ImageSource icon)
            {
                Name = name;
                NameSortKey = name.ToUpperInvariant();
                FullPath = fullPath;
                IsDirectory = isDirectory;
                Type = type;
                TypeSortKey = type.ToUpperInvariant();
                Modified = modified;
                ModifiedAt = modifiedAt;
                _size = size;
                _sizeBytes = sizeBytes;
                GroupName = groupName;
                GroupOrder = groupName == GroupDirectories ? 0 : 1;
                Icon = icon;
            }

            public void UpdateSize(long bytes)
            {
                SizeBytes = bytes;
                Size = SizeDisplayFormatter.FormatBytes(bytes);
            }

            public event PropertyChangedEventHandler? PropertyChanged;
        }
    }

    public sealed class FolderTreeNode
    {
        public string Display { get; }
        public string? Path { get; private set; }
        public FolderTreeNode? Parent { get; set; }
        public ObservableCollection<FolderTreeNode> Children { get; } = new();
        public bool ChildrenLoaded { get; set; }
        public bool IsShadowCopiesRoot { get; }
        public ShadowCopyEntry? ShadowCopy { get; }
        public bool OpensPaneOnSelect { get; set; }

        public FolderTreeNode(string display, string? path, bool isShadowCopiesRoot = false, ShadowCopyEntry? shadowCopy = null)
        {
            Display = display;
            Path = path;
            IsShadowCopiesRoot = isShadowCopiesRoot;
            ShadowCopy = shadowCopy;
            if (ShouldShowExpandPlaceholder())
                Children.Add(PlaceholderNode);
        }

        private static FolderTreeNode PlaceholderNode { get; } = new("\u200B", null);

        private bool ShouldShowExpandPlaceholder()
            => IsShadowCopiesRoot || (ShadowCopy == null && !string.IsNullOrWhiteSpace(Path));

        public void ResetLazyChildren()
        {
            ChildrenLoaded = false;
            Children.Clear();
            if (ShouldShowExpandPlaceholder())
                Children.Add(PlaceholderNode);
        }

        public static FolderTreeNode CreateShadowCopiesRoot() => new("Shadow Copies", null, isShadowCopiesRoot: true);

        public static FolderTreeNode FromShadowCopy(string display, ShadowCopyEntry entry) =>
            new(display, null, shadowCopy: entry);

        public static FolderTreeNode FromDrive(DriveInfo drive)
        {
            var label = string.IsNullOrWhiteSpace(drive.VolumeLabel) ? string.Empty : $" [{drive.VolumeLabel}]";
            var root = drive.RootDirectory.FullName.TrimEnd('\\');
            return new FolderTreeNode($"{root}{label}", drive.RootDirectory.FullName)
            {
                OpensPaneOnSelect = true
            };
        }

        public void SetMountedPath(string path)
        {
            Path = path;
            OpensPaneOnSelect = true;
            ChildrenLoaded = false;
            Children.Clear();
            if (!string.IsNullOrWhiteSpace(path))
                Children.Add(PlaceholderNode);
        }

        public void LoadChildFolders()
        {
            if (ChildrenLoaded || string.IsNullOrWhiteSpace(Path))
                return;

            ChildrenLoaded = true;
            Children.Clear();

            try
            {
                foreach (var dir in Directory.EnumerateDirectories(Path))
                {
                    DirectoryInfo info;
                    try
                    {
                        info = new DirectoryInfo(dir);
                        _ = info.Attributes;
                    }
                    catch
                    {
                        continue;
                    }

                    if (info.Attributes.HasFlag(FileAttributes.ReparsePoint))
                        continue;

                    var child = new FolderTreeNode(info.Name, info.FullName)
                    {
                        Parent = this,
                        OpensPaneOnSelect = OpensPaneOnSelect
                    };
                    Children.Add(child);
                }
            }
            catch
            {
                // Ignore unreadable branches.
            }
        }
    }
}
