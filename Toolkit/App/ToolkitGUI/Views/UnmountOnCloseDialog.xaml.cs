using System.Windows;
using ToolkitGUI.Services;

namespace ToolkitGUI.Views
{
    public partial class UnmountOnCloseDialog : Window
    {
        public UnmountOnCloseDialog()
        {
            InitializeComponent();
            WindowSizingHelper.EnableAdaptiveDialog(this);
        }

        private void ConfirmButton_Click(object sender, RoutedEventArgs e)
        {
            DialogResult = true;
            Close();
        }

        private void CancelButton_Click(object sender, RoutedEventArgs e)
        {
            DialogResult = false;
            Close();
        }
    }
}
